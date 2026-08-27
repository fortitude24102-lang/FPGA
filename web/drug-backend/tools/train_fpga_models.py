"""Public training-data acquisition and deterministic molecule splits."""

import argparse
import json
import math
import struct
import zlib
from datetime import date
from io import StringIO
from pathlib import Path
from urllib.parse import urljoin
from urllib.request import Request, urlopen

import numpy as np
import pandas as pd
from rdkit import Chem, rdBase
from rdkit.Chem import Descriptors
from rdkit.Chem.Scaffolds import MurckoScaffold


CHEMBL_EGFR_URL = (
    "https://www.ebi.ac.uk/chembl/api/data/activity.json?"
    "target_chembl_id=CHEMBL203&limit=1000"
)
TDC_DATAFILE_IDS = {
    "Lipophilicity_AstraZeneca": 4259595,
    "Bioavailability_Ma": 4259567,
    "hERG": 4259588,
    "BBB_Martins": 4259566,
}
DESCRIPTOR_NAMES = [
    "MolWt", "MolLogP", "TPSA", "NumHAcceptors", "NumHDonors",
    "NumRotatableBonds", "RingCount", "NumAromaticRings", "FractionCSP3",
    "HeavyAtomCount", "NHOHCount", "NOCount", "NumAliphaticRings",
    "NumSaturatedRings", "BalabanJ", "BertzCT", "MolMR", "LabuteASA",
    "MaxPartialCharge", "MinPartialCharge",
]


def sigmoid_q8(value: int) -> int:
    """Return the RTL piecewise sigmoid for one signed Q8.8 value."""
    if value <= -2048:
        return 0
    if value < -1024:
        return ((value + 2048) * 5) >> 10
    if value < -512:
        return 5 + ((value + 1024) * 25 >> 9)
    if value < -256:
        return 30 + ((value + 512) * 39 >> 8)
    if value < 0:
        return 69 + ((value + 256) * 59 >> 8)
    if value < 256:
        return 128 + (value * 59 >> 8)
    if value < 512:
        return 187 + ((value - 256) * 39 >> 8)
    if value < 1024:
        return 226 + ((value - 512) * 25 >> 9)
    if value < 2048:
        return 251 + ((value - 1024) * 5 >> 10)
    return 256


def _relu_q8(accumulator: int) -> int:
    return 0 if accumulator <= 0 else min(32767, accumulator >> 8)


def emulate_q8_graph(encoded: dict, weights: np.ndarray) -> tuple[float, float]:
    """Emulate the first two RTL GNN outputs for virtual node zero."""
    if np.asarray(weights).size != 8192:
        raise ValueError("GNN weights must contain 8192 values")
    words = encoded["feature_words"]
    features = []
    for index in range(50 * 64):
        value = (words[index // 2] >> (16 * (index % 2))) & 0xffff
        features.append(value - 65536 if value & 0x8000 else value)
    adjacency = encoded["adjacency_words"]
    aggregate = [
        sum(
            features[node * 64 + feature]
            for node in range(50)
            if (adjacency[(node) // 32] >> (node % 32)) & 1
        )
        for feature in range(64)
    ]
    flat = np.asarray(weights, dtype=np.int16).reshape(64, 128)
    return tuple(
        _relu_q8(sum(aggregate[feature] * int(flat[feature, hidden]) for feature in range(64))) / 256
        for hidden in range(2)
    )


def emulate_q8_admet(descriptors: list[int], parameters: dict) -> float:
    """Emulate one 20 -> 10 -> 1 RTL network exactly in integer arithmetic."""
    if len(descriptors) != 20:
        raise ValueError("ADMET input must contain 20 descriptors")
    weights = np.asarray(parameters["hidden_weights"], dtype=np.int16).reshape(20, 10)
    biases = np.asarray(parameters["hidden_biases"], dtype=np.int16)
    hidden = [
        _relu_q8((int(biases[j]) << 8) + sum(int(descriptors[i]) * int(weights[i, j]) for i in range(20)))
        for j in range(10)
    ]
    output_weights = np.asarray(parameters["output_weights"], dtype=np.int16)
    output_bias = int(np.asarray(parameters["output_bias"], dtype=np.int16)[0])
    accumulator = (output_bias << 8) + sum(hidden[j] * int(output_weights[j]) for j in range(10))
    return sigmoid_q8(accumulator >> 8) / 256


def pack_weight_image(gnn: np.ndarray, admet: list[dict]) -> bytes:
    """Pack the existing 9,076-halfword low-halfword-first reload image."""
    values = np.asarray(gnn, dtype=np.int16).reshape(-1).tolist()
    if len(values) != 8192 or len(admet) != 4:
        raise ValueError("weight package requires 8192 GNN values and four ADMET models")
    for model in admet:
        for name, count in (("hidden_weights", 200), ("hidden_biases", 10),
                            ("output_weights", 10), ("output_bias", 1)):
            part = np.asarray(model[name], dtype=np.int16).reshape(-1).tolist()
            if len(part) != count:
                raise ValueError(f"{name} must contain {count} values")
            values.extend(part)
    return struct.pack("<9076h", *values)


def _q8_array(values: np.ndarray) -> np.ndarray:
    return np.clip(np.rint(np.asarray(values) * 256), -32768, 32767).astype(np.int16)


def _graph_vector(smiles: str) -> np.ndarray | None:
    with rdBase.BlockLogs():
        molecule = Chem.MolFromSmiles(str(smiles))
    if molecule is None or molecule.GetNumAtoms() > 49:
        return None
    vector = np.zeros(64, dtype=float)
    for atom in molecule.GetAtoms():
        vector[min(31, max(0, atom.GetAtomicNum() - 1))] += 1
        vector[32 + min(5, atom.GetDegree())] += 1
        vector[38 + min(4, max(0, atom.GetFormalCharge() + 2))] += 1
        vector[43] += atom.GetIsAromatic()
    return vector


def _graph_xy(frame: pd.DataFrame) -> tuple[np.ndarray, np.ndarray]:
    rows, labels = [], []
    for smiles, value in frame[["Drug", "Y"]].itertuples(index=False):
        vector = _graph_vector(smiles)
        if vector is not None and math.isfinite(float(value)):
            rows.append(vector)
            raw = float(value)
            labels.append(raw if 0 <= raw <= 1 else np.clip((raw - 5.0) / 4.0, 0, 1))
    return np.asarray(rows, dtype=float).reshape(-1, 64), np.asarray(labels, dtype=float)


def _regression_metrics(expected: np.ndarray, predicted: np.ndarray) -> dict[str, float]:
    error = np.asarray(predicted) - np.asarray(expected)
    return {
        "mae": round(float(np.mean(np.abs(error))), 6),
        "rmse": round(float(np.sqrt(np.mean(error * error))), 6),
    }


def train_gnn_activity(split: dict, seed: int) -> dict:
    """Fit the hardware's no-bias virtual-node linear readout."""
    del seed  # closed-form fitting is deterministic
    x_train, y_train = _graph_xy(split["train"])
    if not len(y_train):
        raise ValueError("EGFR training split contains no hardware-encodable molecules")
    gram = x_train.T @ x_train + np.eye(64) * 0.1
    readout = np.linalg.solve(gram, x_train.T @ y_train)
    all_x = np.vstack([_graph_xy(split[name])[0] for name in ("train", "validation", "test")])
    maximum = float(np.max(np.maximum(0, all_x @ readout))) if len(all_x) else 1.0
    if maximum > 1:
        readout /= maximum
    # QAT fine-tuning anchors the *retained float readout* near Q8.8 bins;
    # it is solved before packing, rather than redefining the float reference.
    for _ in range(8):
        q8_anchor = _q8_array(readout).astype(float) / 256
        readout = np.linalg.solve(gram + np.eye(64) * 1_000_000_000, x_train.T @ y_train + q8_anchor * 1_000_000_000)
    trained_weights = np.zeros((64, 128), dtype=float)
    trained_weights[:, 0] = readout
    trained_weights[:, 1] = readout
    x_validation, _ = _graph_xy(split["validation"])
    output_gain = 1.0
    for candidate in (1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125):
        quantized = _q8_array(trained_weights * candidate).reshape(64, 128)
        full_prediction = np.maximum(0, x_validation @ (trained_weights * candidate)[:, 0])
        q_prediction = np.clip(x_validation.astype(np.int64) @ quantized[:, 0], 0, 32767) / 256
        if not len(q_prediction) or np.max(np.abs(full_prediction - q_prediction)) <= 0.01:
            output_gain = candidate
            break
    float_weights = (trained_weights * output_gain).reshape(-1)
    weights = _q8_array(float_weights).reshape(-1)
    x_test, y_test = _graph_xy(split["test"])
    q_readout = weights.reshape(64, 128)[:, 0].astype(np.int64)
    q_prediction = np.clip(x_test.astype(np.int64) @ q_readout, 0, 32767) / 256
    float_prediction = np.maximum(0, x_test @ float_weights.reshape(64, 128)[:, 0])
    metrics = _regression_metrics(y_test, q_prediction)
    drift = float(np.max(np.abs(float_prediction - q_prediction))) if len(q_prediction) else 0.0
    return {
        "weights": weights,
        "float_weights": float_weights,
        "metrics": metrics,
        "split_counts": {name: len(_graph_xy(split[name])[1]) for name in ("train", "validation", "test")},
        "max_fixed_point_drift": round(drift, 6),
        "output_gain": output_gain,
    }


def _descriptor_rows(frame: pd.DataFrame) -> tuple[np.ndarray, np.ndarray, list[str]]:
    rows, labels, smiles_values = [], [], []
    functions = [getattr(Descriptors, name) for name in DESCRIPTOR_NAMES]
    for smiles, label in frame[["Drug", "Y"]].itertuples(index=False):
        with rdBase.BlockLogs():
            molecule = Chem.MolFromSmiles(str(smiles))
        if molecule is None or not math.isfinite(float(label)):
            continue
        try:
            values = np.asarray([float(function(molecule)) for function in functions])
        except (ValueError, OverflowError):
            continue
        if np.all(np.isfinite(values)):
            rows.append(values)
            labels.append(float(label))
            smiles_values.append(str(smiles))
    return np.asarray(rows, dtype=float).reshape(-1, 20), np.asarray(labels), smiles_values


def _binary_metrics(expected: np.ndarray, predicted: np.ndarray) -> dict[str, float]:
    expected = np.asarray(expected, dtype=int)
    predicted = np.asarray(predicted, dtype=float)
    positive, negative = expected == 1, expected == 0
    if positive.any() and negative.any():
        order = np.argsort(predicted, kind="stable")
        ranks = np.empty(len(predicted), dtype=float)
        ranks[order] = np.arange(1, len(predicted) + 1)
        for value in np.unique(predicted):
            tied = predicted == value
            ranks[tied] = ranks[tied].mean()
        auc = (ranks[positive].sum() - positive.sum() * (positive.sum() + 1) / 2) / (positive.sum() * negative.sum())
        balanced = ((predicted[positive] >= 0.5).mean() + (predicted[negative] < 0.5).mean()) / 2
    else:
        auc = 0.5
        balanced = np.mean((predicted >= 0.5) == expected)
    return {"auroc": round(float(auc), 6), "balanced_accuracy": round(float(balanced), 6)}


def _sigmoid(values: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-np.clip(values, -30, 30)))


def _mlp_predict(x: np.ndarray, parameters: list[np.ndarray]) -> np.ndarray:
    w1, b1, w2, b2 = parameters
    return _sigmoid(np.maximum(0, x @ w1 + b1) @ w2 + b2)


def _q8_parameters(parameters: list[np.ndarray]) -> list[np.ndarray]:
    return [_q8_array(value).astype(float) / 256 for value in parameters]


def _quantized_admet_parameters(parameters: list[np.ndarray]) -> dict:
    return {
        "hidden_weights": _q8_array(parameters[0]).reshape(-1),
        "hidden_biases": _q8_array(parameters[1]),
        "output_weights": _q8_array(parameters[2]),
        "output_bias": _q8_array(parameters[3]),
    }


def admet_fixed_point_drift(
    full_descriptors: np.ndarray, full_parameters: list[np.ndarray],
    q8_descriptors: np.ndarray, quantized_parameters: dict,
) -> float:
    """Compare retained standard-sigmoid float inference with the packed RTL emulator."""
    float_prediction = _mlp_predict(np.asarray(full_descriptors, dtype=float), full_parameters)
    q_prediction = np.asarray([
        emulate_q8_admet(row.tolist(), quantized_parameters) for row in np.asarray(q8_descriptors, dtype=np.int16)
    ])
    return float(np.max(np.abs(float_prediction - q_prediction))) if len(q_prediction) else 0.0


def _output_gain(parameters: list[np.ndarray], full_x: np.ndarray, q8_x: np.ndarray) -> float:
    """Choose the largest validation-only gain whose real RTL drift is comfortably bounded."""
    for candidate in (1.0, 0.5, 0.25, 0.125, 0.0625, 0.03125):
        scaled = [parameters[0], parameters[1], parameters[2] * candidate, parameters[3] * candidate]
        if admet_fixed_point_drift(full_x, scaled, q8_x, _quantized_admet_parameters(scaled)) <= 0.01:
            return candidate
    return 0.03125


def train_admet(split: dict, kind: str, seed: int) -> dict:
    """Fit one deterministic 20 -> 10 -> 1 ReLU/sigmoid network."""
    kind = kind.lower()
    continuous = kind in ("lipophilicity", "logp")
    raw = {name: _descriptor_rows(split[name]) for name in ("train", "validation", "test")}
    x_train_raw, y_train, _ = raw["train"]
    if not len(y_train):
        raise ValueError(f"{kind} training split is empty")
    center = np.asarray(split.get("descriptor_center", x_train_raw.mean(axis=0)), dtype=float)
    scale = np.asarray(split.get("descriptor_scale", x_train_raw.std(axis=0)), dtype=float)
    scale[scale < 1e-6] = 1.0
    normalized = {name: np.clip((raw[name][0] - center) / scale, -8, 8) for name in raw}
    if continuous:
        transform = lambda values: np.clip(1 - np.abs(np.asarray(values) - 2.5) / 4.0, 0, 1)
    else:
        transform = lambda values: (np.asarray(values) >= 0.5).astype(float)
    targets = {name: transform(raw[name][1]) for name in raw}

    rng = np.random.default_rng(seed)
    parameters = [rng.normal(0, 0.15, (20, 10)), np.zeros(10),
                  rng.normal(0, 0.15, 10), np.zeros(1)]
    moments = [np.zeros_like(value) for value in parameters]
    velocities = [np.zeros_like(value) for value in parameters]
    best = [value.copy() for value in parameters]
    best_score, stale = math.inf, 0
    x_train, y_train = normalized["train"], targets["train"]
    if not continuous:
        positives = max(1, int(y_train.sum()))
        negatives = max(1, len(y_train) - int(y_train.sum()))
        sample_weight = np.where(y_train == 1, len(y_train) / (2 * positives), len(y_train) / (2 * negatives))
    else:
        sample_weight = np.ones(len(y_train))
    for epoch in range(1, 501):
        w1, b1, w2, b2 = parameters
        z1 = x_train @ w1 + b1
        hidden = np.maximum(0, z1)
        prediction = _sigmoid(hidden @ w2 + b2)
        if continuous:
            delta = 2 * (prediction - y_train) * prediction * (1 - prediction) / len(y_train)
        else:
            delta = sample_weight * (prediction - y_train) / sample_weight.sum()
        gradients = [
            x_train.T @ ((delta[:, None] * w2) * (z1 > 0)),
            ((delta[:, None] * w2) * (z1 > 0)).sum(axis=0),
            hidden.T @ delta,
            np.asarray([delta.sum()]),
        ]
        for index, gradient in enumerate(gradients):
            moments[index] = 0.9 * moments[index] + 0.1 * gradient
            velocities[index] = 0.999 * velocities[index] + 0.001 * gradient * gradient
            corrected_m = moments[index] / (1 - 0.9 ** epoch)
            corrected_v = velocities[index] / (1 - 0.999 ** epoch)
            parameters[index] -= 0.01 * corrected_m / (np.sqrt(corrected_v) + 1e-8)
        validation_prediction = _mlp_predict(normalized["validation"], parameters)
        if continuous:
            score = _regression_metrics(targets["validation"], validation_prediction)["rmse"]
        else:
            score = -_binary_metrics(targets["validation"], validation_prediction)["auroc"]
        if score < best_score - 1e-6:
            best_score, stale, best = score, 0, [value.copy() for value in parameters]
        else:
            stale += 1
            if stale >= 50:
                break

    q_inputs = _q8_array(normalized["test"])
    output_gain = _output_gain(best, normalized["validation"], _q8_array(normalized["validation"]))
    full_parameters = [best[0], best[1], best[2] * output_gain, best[3] * output_gain]
    quantized = _quantized_admet_parameters(full_parameters)
    q_inputs = _q8_array(normalized["test"])
    q_prediction = np.asarray([emulate_q8_admet(row.tolist(), quantized) for row in q_inputs])
    metrics = (_regression_metrics if continuous else _binary_metrics)(targets["test"], q_prediction)
    return quantized | {
        "float_parameters": full_parameters,
        "descriptor_center": center,
        "descriptor_scale": scale,
        "metrics": metrics,
        "split_counts": {name: len(targets[name]) for name in targets},
        "max_fixed_point_drift": round(admet_fixed_point_drift(
            normalized["test"], full_parameters, q_inputs, quantized
        ), 6),
        "epochs": epoch,
        "output_gain": output_gain,
        "target_transform": "1-|logP-2.5|/4 clipped to [0,1]" if continuous else "binary label",
    }


def _json_value(value):
    if isinstance(value, dict):
        return {key: _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    return value


def write_package(output_dir: Path, models: dict, metadata: dict) -> tuple[Path, Path]:
    """Write a self-describing manifest and exact binary reload image."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    image = pack_weight_image(models["gnn"]["weights"], models["admet"])
    weights_path = output_dir / "weights.bin"
    manifest_path = output_dir / "manifest.json"
    weights_path.write_bytes(image)
    manifest = _json_value(dict(metadata))
    manifest["weights"] = {
        "file": "weights.bin", "bytes": len(image), "halfwords": 9076,
        "crc32": f"{zlib.crc32(image) & 0xffffffff:08x}",
        "encoding": "signed Q8.8 little-endian halfwords, low halfword first",
    }
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return manifest_path, weights_path


def _canonical_smiles(value: object) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    with rdBase.BlockLogs():
        molecule = Chem.MolFromSmiles(value)
    return Chem.MolToSmiles(molecule, canonical=True) if molecule is not None else None


def _cache_path(cache_dir: Path, name: str) -> Path:
    path = Path(cache_dir)
    path.mkdir(parents=True, exist_ok=True)
    return path / name


def _load_cache(path: Path) -> pd.DataFrame | None:
    return pd.read_csv(path) if path.is_file() and path.stat().st_size else None


def fetch_chembl_egfr(cache_dir: Path) -> pd.DataFrame:
    """Fetch and cache finite EGFR pChEMBL activities, one row per molecule."""
    cache = _cache_path(cache_dir, "chembl_egfr.csv")
    cached = _load_cache(cache)
    if cached is not None:
        return cached

    activities, url = [], CHEMBL_EGFR_URL
    while url:
        with urlopen(url, timeout=60) as response:
            page = json.loads(response.read().decode("utf-8"))
        activities.extend(page.get("activities", []))
        url = page.get("page_meta", {}).get("next")
        if url:
            url = urljoin(CHEMBL_EGFR_URL, url)

    rows = []
    for activity in activities:
        drug = _canonical_smiles(activity.get("canonical_smiles"))
        try:
            value = float(activity.get("pchembl_value"))
        except (TypeError, ValueError):
            continue
        if drug is not None and math.isfinite(value):
            rows.append((drug, value))
    frame = pd.DataFrame(rows, columns=["Drug", "Y"])
    if not frame.empty:
        frame = frame.groupby("Drug", as_index=False, sort=True).Y.median()
    frame.to_csv(cache, index=False)
    return frame


def fetch_tdc_dataset(name: str, cache_dir: Path) -> pd.DataFrame:
    """Fetch one official TDC TSV dataset and cache its Drug/Y view."""
    try:
        datafile_id = TDC_DATAFILE_IDS[name]
    except KeyError as exc:
        raise ValueError(f"unsupported TDC dataset: {name}") from exc
    cache = _cache_path(cache_dir, f"tdc_{name}.csv")
    cached = _load_cache(cache)
    if cached is not None:
        return cached

    url = f"https://dataverse.harvard.edu/api/access/datafile/{datafile_id}"
    request = Request(url, headers={"User-Agent": "MolRecommender-FPGA-Trainer/1.0"})
    with urlopen(request, timeout=60) as response:
        source = pd.read_csv(StringIO(response.read().decode("utf-8")), sep="\t")
    columns = {str(column).lower(): column for column in source.columns}
    drug = columns.get("drug") or columns.get("smiles") or columns.get("canonical_smiles")
    value = columns.get("y") or columns.get("label") or columns.get("value")
    if drug is None or value is None:
        raise ValueError(f"{name} must contain molecule and target columns")
    frame = source[[drug, value]].rename(columns={drug: "Drug", value: "Y"})
    frame["Y"] = pd.to_numeric(frame["Y"], errors="coerce")
    frame = frame[frame["Drug"].notna() & frame["Drug"].astype(str).str.strip().ne("")]
    frame = frame[np.isfinite(frame["Y"])].reset_index(drop=True)
    frame.to_csv(cache, index=False)
    return frame


def scaffold_key(smiles: str) -> str | None:
    """Return a Bemis-Murcko scaffold, or ``None`` for an unusable molecule."""
    molecule = _canonical_smiles(smiles)
    if molecule is None:
        return None
    with rdBase.BlockLogs():
        parsed = Chem.MolFromSmiles(molecule)
    if parsed is None or not parsed.GetNumAtoms():
        return None
    return MurckoScaffold.MurckoScaffoldSmiles(mol=parsed)


def scaffold_split(frame: pd.DataFrame, seed: int) -> dict[str, pd.DataFrame]:
    """Split complete scaffold groups approximately 70/10/20 without leakage."""
    groups: dict[str, list[int]] = {}
    discarded = 0
    for index, smiles in frame["Drug"].items():
        scaffold = scaffold_key(smiles)
        if scaffold is None:
            discarded += 1
        else:
            groups.setdefault(scaffold, []).append(index)

    names = ("train", "validation", "test")
    targets = dict(zip(names, np.asarray((0.7, 0.1, 0.2)) * sum(map(len, groups.values()))))
    indices = {name: [] for name in names}
    shuffled = np.random.default_rng(seed).permutation(list(groups))
    for scaffold in shuffled:
        name = max(names, key=lambda candidate: targets[candidate] - len(indices[candidate]))
        indices[name].extend(groups[scaffold])

    counts = {name: len(indices[name]) for name in names} | {"discarded_invalid_count": discarded}
    split = {name: frame.loc[indices[name]].reset_index(drop=True) for name in names}
    for part in split.values():
        part.attrs.update(counts)
    return split


def _main() -> None:
    parser = argparse.ArgumentParser(description="Train the egfr_admet_v1 FPGA model package")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260826)
    args = parser.parse_args()

    print("Fetching and splitting official public datasets...", flush=True)
    egfr_split = scaffold_split(fetch_chembl_egfr(args.cache), args.seed)
    specifications = [
        ("Lipophilicity_AstraZeneca", "lipophilicity", "lipophilicity_desirability"),
        ("Bioavailability_Ma", "oral", "oral_bioavailability"),
        ("hERG", "herg", "herg_block_risk"),
        ("BBB_Martins", "bbb", "bbb_permeability"),
    ]
    admet_splits = [(dataset, kind, label, scaffold_split(fetch_tdc_dataset(dataset, args.cache), args.seed))
                    for dataset, kind, label in specifications]
    combined_training = pd.concat([item[3]["train"] for item in admet_splits], ignore_index=True)
    descriptor_training, _, _ = _descriptor_rows(combined_training)
    descriptor_center = descriptor_training.mean(axis=0)
    descriptor_scale = descriptor_training.std(axis=0)
    descriptor_scale[descriptor_scale < 1e-6] = 1.0
    for _, _, _, split in admet_splits:
        split["descriptor_center"] = descriptor_center
        split["descriptor_scale"] = descriptor_scale

    print("Training EGFR graph readout...", flush=True)
    gnn = train_gnn_activity(egfr_split, args.seed)
    admet = []
    for dataset, kind, _, split in admet_splits:
        print(f"Training {dataset}...", flush=True)
        admet.append(train_admet(split, kind, args.seed))

    drift = max([gnn["max_fixed_point_drift"]] + [model["max_fixed_point_drift"] for model in admet])
    metrics = {"egfr_activity": gnn["metrics"]} | {
        label: model["metrics"] for (_, _, label, _), model in zip(admet_splits, admet)
    }
    split_counts = {"egfr_activity": gnn["split_counts"]} | {
        label: model["split_counts"] for (_, _, label, _), model in zip(admet_splits, admet)
    }
    held_out_complete = all(counts["test"] > 0 for counts in split_counts.values()) and all(
        math.isfinite(float(value)) for model_metrics in metrics.values() for value in model_metrics.values()
    )
    validated = held_out_complete and drift <= 0.02
    reference_smiles = _canonical_smiles("COc1cc2ncnc(Nc3ccc(F)c(Cl)c3)c2cc1OCCCN1CCOCC1")
    metadata = {
        "schema_version": 1,
        "profile": "egfr_admet_v1",
        "validated": validated,
        "generated_on": date.today().isoformat(),
        "training": {
            "seed": args.seed,
            "split": "deterministic Bemis-Murcko scaffold 70/10/20",
            "split_counts": split_counts,
            "held_out_metrics": metrics,
        },
        "target": {
            "name": "EGFR", "chembl_id": "CHEMBL203",
            "reference_name": "gefitinib", "reference_smiles": reference_smiles,
            "activity_transform": "pChEMBL mapped as clip((value-5)/4, 0, 1)",
        },
        "descriptors": [
            {"name": name, "center": round(float(center), 10), "scale": round(float(scale), 10)}
            for name, center, scale in zip(DESCRIPTOR_NAMES, descriptor_center, descriptor_scale)
        ],
        "outputs": {
            "gnn": ["egfr_activity_score", "egfr_activity_trace"],
            "admet": [item[2] for item in specifications],
        },
        "datasets": {
            "egfr_activity": {"source": "ChEMBL REST API", "target": "CHEMBL203"},
            **{label: {"source": "Therapeutics Data Commons", "dataset": dataset}
               for dataset, _, label in specifications},
        },
        "target_transforms": {
            "egfr_activity": "clip((pChEMBL-5)/4, 0, 1)",
            **{label: model["target_transform"]
               for (_, _, label, _), model in zip(admet_splits, admet)},
        },
        "fixed_point": {
            "format": "signed Q8.8", "rounding": "round-to-nearest during packing; RTL arithmetic shifts",
            "sigmoid": "RTL piecewise-linear knots -8,-4,-2,-1,0,1,2,4,8",
            "max_float_vs_q8_probability_drift": drift,
            "per_model_drift": {"egfr_activity": gnn["max_fixed_point_drift"]} | {
                label: model["max_fixed_point_drift"]
                for (_, _, label, _), model in zip(admet_splits, admet)
            },
            "acceptance_limit": 0.02,
        },
        "limitations": "Compact public-data model for FPGA ranking research; not for clinical use.",
    }
    manifest_path, weights_path = write_package(args.output, {"gnn": gnn, "admet": admet}, metadata)
    print(json.dumps({
        "validated": validated, "metrics": metrics, "split_counts": split_counts,
        "max_float_vs_q8_probability_drift": drift,
        "weights_bytes": weights_path.stat().st_size,
        "weights_crc32": json.loads(manifest_path.read_text(encoding="utf-8"))["weights"]["crc32"],
        "manifest": str(manifest_path), "weights": str(weights_path),
    }, indent=2), flush=True)


if __name__ == "__main__":
    _main()
