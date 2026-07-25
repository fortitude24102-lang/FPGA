#!/usr/bin/env python3
"""Generate deterministic FPGA vectors and fixed-point reference results.

RDKit is used when it is installed.  A dependency-free synthetic mode is
provided so RTL regression can still run on machines without RDKit/PyTorch.
All hardware values use signed Q8.8 unless a field explicitly says Q16.16.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path
from typing import Callable, Iterable, Sequence


DATA_WIDTH = 16
FRAC_BITS = 8
Q8_SCALE = 1 << FRAC_BITS
Q8_MIN = -(1 << (DATA_WIDTH - 1))
Q8_MAX = (1 << (DATA_WIDTH - 1)) - 1


def q8(value: float) -> int:
    """Round a float to a signed Q8.8 integer with saturation."""
    scaled = int(round(value * Q8_SCALE))
    return min(Q8_MAX, max(Q8_MIN, scaled))


def signed_to_hex(value: int, width: int = DATA_WIDTH) -> str:
    return f"{value & ((1 << width) - 1):0{(width + 3) // 4}x}"


def pack_lsb_first(values: Sequence[int], width: int) -> int:
    packed = 0
    mask = (1 << width) - 1
    for index, value in enumerate(values):
        packed |= (value & mask) << (index * width)
    return packed


def population_count(value: int) -> int:
    if hasattr(value, "bit_count"):
        return value.bit_count()
    return bin(value).count("1")


def sigmoid_piecewise_q8(x_q8: int) -> int:
    """Match fc_network.v's piecewise-linear sigmoid exactly."""
    if x_q8 <= -2048:
        return 0
    if x_q8 < -1024:
        return ((x_q8 + 2048) * 5) >> 10
    if x_q8 < -512:
        return 5 + (((x_q8 + 1024) * 25) >> 9)
    if x_q8 < -256:
        return 30 + (((x_q8 + 512) * 39) >> 8)
    if x_q8 < 0:
        return 69 + (((x_q8 + 256) * 59) >> 8)
    if x_q8 < 256:
        return 128 + ((x_q8 * 59) >> 8)
    if x_q8 < 512:
        return 187 + (((x_q8 - 256) * 39) >> 8)
    if x_q8 < 1024:
        return 226 + (((x_q8 - 512) * 25) >> 9)
    if x_q8 < 2048:
        return 251 + (((x_q8 - 1024) * 5) >> 10)
    return 256


def tanimoto_reference(query: int, database: int) -> dict[str, float | int]:
    intersection = population_count(query & database)
    union = population_count(query | database)
    q16 = 0 if union == 0 else (intersection << 16) // union
    return {
        "intersection_count": intersection,
        "union_count": union,
        "q16_16": q16,
        "float": q16 / 65536.0,
    }


def gnn_reference(
    features: Sequence[Sequence[int]],
    adjacency: Sequence[Sequence[int]],
    weights: Sequence[Sequence[int]],
    max_nodes: int,
    feature_dim: int,
    hidden_dim: int,
) -> list[list[int]]:
    output = [[0 for _ in range(hidden_dim)] for _ in range(max_nodes)]
    for node in range(max_nodes):
        aggregate = [0 for _ in range(feature_dim)]
        for neighbor in range(max_nodes):
            if adjacency[node][neighbor]:
                for feature in range(feature_dim):
                    aggregate[feature] += features[neighbor][feature]
        for hidden in range(hidden_dim):
            accumulator = 0
            for feature in range(feature_dim):
                accumulator += weights[feature][hidden] * aggregate[feature]
            quantized = accumulator >> FRAC_BITS
            output[node][hidden] = min(Q8_MAX, max(0, quantized))
    return output


def fc_reference(
    inputs: Sequence[int],
    hidden_weights: Sequence[Sequence[int]],
    hidden_biases: Sequence[int],
    output_weights: Sequence[int],
    output_bias: int,
) -> int:
    hidden_values: list[int] = []
    for hidden, bias in enumerate(hidden_biases):
        accumulator = bias << FRAC_BITS
        for input_index, input_value in enumerate(inputs):
            accumulator += input_value * hidden_weights[input_index][hidden]
        hidden_values.append(min(Q8_MAX, max(0, accumulator >> FRAC_BITS)))

    accumulator = output_bias << FRAC_BITS
    for hidden, hidden_value in enumerate(hidden_values):
        accumulator += hidden_value * output_weights[hidden]
    return sigmoid_piecewise_q8(accumulator >> FRAC_BITS)


def random_matrix(
    rng: random.Random, rows: int, columns: int, low: float, high: float
) -> list[list[int]]:
    return [
        [q8(rng.uniform(low, high)) for _ in range(columns)]
        for _ in range(rows)
    ]


def synthetic_molecules(
    rng: random.Random,
    count: int,
    max_nodes: int,
    feature_dim: int,
    fingerprint_bits: int,
) -> list[dict[str, object]]:
    molecules: list[dict[str, object]] = []
    for molecule_index in range(count):
        node_count = min(max_nodes, 4 + molecule_index)
        fingerprint = rng.getrandbits(fingerprint_bits)
        features = [[0 for _ in range(feature_dim)] for _ in range(max_nodes)]
        for node in range(node_count):
            for feature in range(feature_dim):
                features[node][feature] = q8(rng.uniform(-1.0, 1.0))
        adjacency = [[0 for _ in range(max_nodes)] for _ in range(max_nodes)]
        for node in range(node_count):
            adjacency[node][node] = 1
            if node + 1 < node_count:
                adjacency[node][node + 1] = 1
                adjacency[node + 1][node] = 1
        descriptors = [q8(rng.uniform(-1.0, 1.0)) for _ in range(20)]
        molecules.append(
            {
                "name": f"synthetic_{molecule_index}",
                "smiles": None,
                "fingerprint": fingerprint,
                "node_count": node_count,
                "features": features,
                "adjacency": adjacency,
                "descriptors": descriptors,
            }
        )
    return molecules


def rdkit_molecules(
    smiles_values: Sequence[str],
    max_nodes: int,
    feature_dim: int,
    fingerprint_bits: int,
) -> list[dict[str, object]]:
    try:
        from rdkit import Chem, DataStructs
        from rdkit.Chem import AllChem, Descriptors
    except ImportError as exc:
        raise RuntimeError(
            "RDKit is not installed. Install RDKit or run with --synthetic."
        ) from exc

    descriptor_specs: list[tuple[Callable[[object], float], float, float]] = [
        (Descriptors.MolWt, 300.0, 100.0),
        (Descriptors.MolLogP, 0.0, 5.0),
        (Descriptors.NumHDonors, 0.0, 5.0),
        (Descriptors.NumHAcceptors, 0.0, 10.0),
        (Descriptors.TPSA, 0.0, 100.0),
        (Descriptors.NumRotatableBonds, 0.0, 10.0),
        (Descriptors.RingCount, 0.0, 8.0),
        (Descriptors.FractionCSP3, 0.0, 1.0),
        (Descriptors.HeavyAtomCount, 0.0, 50.0),
        (Descriptors.NHOHCount, 0.0, 10.0),
        (Descriptors.NOCount, 0.0, 20.0),
        (Descriptors.NumAromaticRings, 0.0, 8.0),
        (Descriptors.NumAliphaticRings, 0.0, 8.0),
        (Descriptors.NumSaturatedRings, 0.0, 8.0),
        (Descriptors.NumHeteroatoms, 0.0, 20.0),
        (Descriptors.MaxPartialCharge, 0.0, 1.0),
        (Descriptors.MinPartialCharge, 0.0, 1.0),
        (Descriptors.BalabanJ, 0.0, 5.0),
        (Descriptors.BertzCT, 0.0, 500.0),
        (Descriptors.MolMR, 0.0, 100.0),
    ]

    molecules: list[dict[str, object]] = []
    for molecule_index, smiles in enumerate(smiles_values):
        molecule = Chem.MolFromSmiles(smiles)
        if molecule is None:
            raise ValueError(f"Invalid SMILES at line {molecule_index + 1}: {smiles}")
        if molecule.GetNumAtoms() > max_nodes:
            raise ValueError(
                f"{smiles} has {molecule.GetNumAtoms()} atoms; max is {max_nodes}"
            )

        try:
            generator = AllChem.GetMorganGenerator(
                radius=2, fpSize=fingerprint_bits
            )
            bit_vector = generator.GetFingerprint(molecule)
        except AttributeError:
            bit_vector = AllChem.GetMorganFingerprintAsBitVect(
                molecule, 2, nBits=fingerprint_bits
            )
        on_bits = list(bit_vector.GetOnBits())
        fingerprint = sum(1 << bit for bit in on_bits)

        features = [[0 for _ in range(feature_dim)] for _ in range(max_nodes)]
        for atom in molecule.GetAtoms():
            node = atom.GetIdx()
            atomic_index = min(31, max(0, atom.GetAtomicNum() - 1))
            features[node][atomic_index] = q8(1.0)
            features[node][32 + min(5, atom.GetDegree())] = q8(1.0)
            charge_index = min(4, max(0, atom.GetFormalCharge() + 2))
            features[node][38 + charge_index] = q8(1.0)
            features[node][43] = q8(float(atom.GetIsAromatic()))

        adjacency = [[0 for _ in range(max_nodes)] for _ in range(max_nodes)]
        for node in range(molecule.GetNumAtoms()):
            adjacency[node][node] = 1
        for bond in molecule.GetBonds():
            begin = bond.GetBeginAtomIdx()
            end = bond.GetEndAtomIdx()
            adjacency[begin][end] = 1
            adjacency[end][begin] = 1

        descriptors = []
        for function, center, scale in descriptor_specs:
            raw_value = function(molecule)
            if not math.isfinite(raw_value):
                raw_value = 0.0
            descriptors.append(q8((raw_value - center) / scale))

        molecules.append(
            {
                "name": f"molecule_{molecule_index}",
                "smiles": smiles,
                "fingerprint": fingerprint,
                "node_count": molecule.GetNumAtoms(),
                "features": features,
                "adjacency": adjacency,
                "descriptors": descriptors,
            }
        )
    return molecules


def write_lines(path: Path, lines: Iterable[str]) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def generate(args: argparse.Namespace) -> dict[str, object]:
    rng = random.Random(args.seed)
    if args.synthetic:
        molecules = synthetic_molecules(
            rng,
            args.count,
            args.max_nodes,
            args.feature_dim,
            args.fingerprint_bits,
        )
        backend = "synthetic"
    else:
        smiles_values = [
            line.strip()
            for line in args.smiles_file.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        molecules = rdkit_molecules(
            smiles_values,
            args.max_nodes,
            args.feature_dim,
            args.fingerprint_bits,
        )
        backend = "rdkit"

    gnn_weights = random_matrix(
        rng, args.feature_dim, args.hidden_dim, -0.25, 0.25
    )
    admet_models: list[dict[str, object]] = []
    for _ in range(4):
        admet_models.append(
            {
                "hidden_weights": random_matrix(rng, 20, 10, -0.5, 0.5),
                "hidden_biases": [q8(rng.uniform(-0.25, 0.25)) for _ in range(10)],
                "output_weights": [q8(rng.uniform(-0.5, 0.5)) for _ in range(10)],
                "output_bias": q8(rng.uniform(-0.25, 0.25)),
            }
        )

    query_fingerprint = int(molecules[0]["fingerprint"])
    for molecule in molecules:
        features = molecule["features"]
        adjacency = molecule["adjacency"]
        descriptors = molecule["descriptors"]
        molecule["tanimoto_reference"] = tanimoto_reference(
            query_fingerprint, int(molecule["fingerprint"])
        )
        molecule["gnn_reference"] = gnn_reference(
            features,
            adjacency,
            gnn_weights,
            args.max_nodes,
            args.feature_dim,
            args.hidden_dim,
        )
        molecule["admet_reference"] = [
            fc_reference(
                descriptors,
                model["hidden_weights"],
                model["hidden_biases"],
                model["output_weights"],
                int(model["output_bias"]),
            )
            for model in admet_models
        ]

    output_dir: Path = args.out_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    hex_width = (args.fingerprint_bits + 3) // 4
    write_lines(
        output_dir / "fingerprints.mem",
        (
            f"{int(molecule['fingerprint']):0{hex_width}x}"
            for molecule in molecules
        ),
    )
    write_lines(
        output_dir / "gnn_weights_q8_8.mem",
        (
            signed_to_hex(gnn_weights[feature][hidden])
            for feature in range(args.feature_dim)
            for hidden in range(args.hidden_dim)
        ),
    )

    for molecule_index, molecule in enumerate(molecules):
        features = molecule["features"]
        adjacency = molecule["adjacency"]
        gnn_output = molecule["gnn_reference"]
        adjacency_flat = [
            adjacency[row][column]
            for row in range(args.max_nodes)
            for column in range(args.max_nodes)
        ]
        write_lines(
            output_dir / f"molecule_{molecule_index}_features_q8_8.mem",
            (
                signed_to_hex(features[node][feature])
                for node in range(args.max_nodes)
                for feature in range(args.feature_dim)
            ),
        )
        adjacency_integer = pack_lsb_first(adjacency_flat, 1)
        adjacency_width = (args.max_nodes * args.max_nodes + 3) // 4
        write_lines(
            output_dir / f"molecule_{molecule_index}_adjacency.mem",
            [f"{adjacency_integer:0{adjacency_width}x}"],
        )
        write_lines(
            output_dir / f"molecule_{molecule_index}_gnn_reference.mem",
            (
                signed_to_hex(gnn_output[node][hidden])
                for node in range(args.max_nodes)
                for hidden in range(args.hidden_dim)
            ),
        )

    for model_index, model in enumerate(admet_models):
        write_lines(
            output_dir / f"admet_{model_index}_hidden_weights.mem",
            (
                signed_to_hex(model["hidden_weights"][input_index][hidden])
                for input_index in range(20)
                for hidden in range(10)
            ),
        )
        write_lines(
            output_dir / f"admet_{model_index}_hidden_biases.mem",
            (signed_to_hex(value) for value in model["hidden_biases"]),
        )
        write_lines(
            output_dir / f"admet_{model_index}_output_weights.mem",
            (signed_to_hex(value) for value in model["output_weights"]),
        )
        write_lines(
            output_dir / f"admet_{model_index}_output_bias.mem",
            [signed_to_hex(int(model["output_bias"]))],
        )

    manifest = {
        "format_version": 1,
        "seed": args.seed,
        "backend": backend,
        "numeric_format": {
            "features_weights_descriptors": "signed Q8.8",
            "tanimoto": "unsigned Q16.16",
        },
        "dimensions": {
            "fingerprint_bits": args.fingerprint_bits,
            "max_nodes": args.max_nodes,
            "feature_dim": args.feature_dim,
            "hidden_dim": args.hidden_dim,
        },
        "molecules": molecules,
        "gnn_weights": gnn_weights,
        "admet_models": admet_models,
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--smiles-file",
        type=Path,
        help="UTF-8 file with one SMILES string per line (requires RDKit)",
    )
    parser.add_argument(
        "--synthetic",
        action="store_true",
        help="generate dependency-free synthetic molecules",
    )
    parser.add_argument("--count", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20260723)
    parser.add_argument("--fingerprint-bits", type=int, default=1024)
    parser.add_argument("--max-nodes", type=int, default=50)
    parser.add_argument("--feature-dim", type=int, default=64)
    parser.add_argument("--hidden-dim", type=int, default=128)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "test_data",
    )
    args = parser.parse_args()
    if not args.synthetic and args.smiles_file is None:
        parser.error("provide --smiles-file or select --synthetic")
    if args.count < 1:
        parser.error("--count must be positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        manifest = generate(args)
    except (RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(
        f"Generated {len(manifest['molecules'])} vectors in {args.out_dir} "
        f"using {manifest['backend']} data."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
