"""Shared FPGA model-profile validation and hardware-native encoders."""

import json
import math
import zlib
from pathlib import Path


Q8_SCALE = 256
GNN_WEIGHT_COUNT = 8192
ADMET_MODEL_COUNT = 4
ADMET_VALUES_PER_MODEL = 221
WEIGHT_HALFWORDS = GNN_WEIGHT_COUNT + ADMET_MODEL_COUNT * ADMET_VALUES_PER_MODEL
WEIGHT_BYTES = WEIGHT_HALFWORDS * 2
MAX_NODES = 50
MAX_REAL_ATOMS = 49
FEATURE_DIM = 64
ADJACENCY_WORDS = 79
FEATURE_WORDS = 1600
DESCRIPTOR_COUNT = 20
GNN_OUTPUTS = ("egfr_activity_score", "egfr_activity_trace")
ADMET_OUTPUTS = (
    "lipophilicity_desirability", "oral_bioavailability",
    "herg_block_risk", "bbb_permeability",
)


def q8(value: float) -> int:
    return min(32767, max(-32768, int(round(value * Q8_SCALE))))


def _validate_profile(profile: dict) -> None:
    if not isinstance(profile, dict):
        raise ValueError("model manifest must be a JSON object")
    if not isinstance(profile.get("profile"), str):
        raise ValueError("model manifest is missing profile")
    target = profile.get("target")
    if not isinstance(target, dict) or not isinstance(target.get("name"), str):
        raise ValueError("model manifest is missing target name")
    reference_smiles = target.get("reference_smiles")
    if not isinstance(reference_smiles, str):
        raise ValueError("model manifest is missing target reference SMILES")
    from rdkit import Chem
    if Chem.MolFromSmiles(reference_smiles) is None:
        raise ValueError("model manifest has invalid target reference SMILES")
    weights = profile.get("weights")
    if not isinstance(weights, dict) or "bytes" not in weights or "crc32" not in weights:
        raise ValueError("model manifest is missing weight metadata")
    descriptors = profile.get("descriptors")
    if not isinstance(descriptors, list) or len(descriptors) != DESCRIPTOR_COUNT:
        raise ValueError("model manifest must define 20 descriptors")
    for descriptor in descriptors:
        if not isinstance(descriptor, dict) or not isinstance(descriptor.get("name"), str):
            raise ValueError("each descriptor must have a name")
        try:
            center, scale = float(descriptor["center"]), float(descriptor["scale"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("each descriptor must have numeric center and scale") from exc
        if not math.isfinite(center) or not math.isfinite(scale) or scale == 0:
            raise ValueError("descriptor scales must be finite and non-zero")
    outputs = profile.get("outputs")
    if not isinstance(outputs, dict) or set(outputs) != {"gnn", "admet"} or (
            tuple(outputs.get("gnn", ())) != GNN_OUTPUTS or
            tuple(outputs.get("admet", ())) != ADMET_OUTPUTS):
        raise ValueError("model manifest has an invalid output contract")


def load_profile(profile_dir: Path) -> dict:
    """Load and structurally validate a profile manifest from ``profile_dir``."""
    try:
        profile = json.loads((Path(profile_dir) / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"unable to load model manifest: {exc}") from exc
    _validate_profile(profile)
    return profile


def validate_weight_image(profile: dict, image: bytes) -> None:
    expected = int(profile["weights"]["bytes"])
    if expected != WEIGHT_BYTES or len(image) != WEIGHT_BYTES:
        raise ValueError(f"weight image must contain {WEIGHT_BYTES} bytes")
    observed = f"{zlib.crc32(image) & 0xffffffff:08x}"
    if observed != str(profile["weights"]["crc32"]).lower():
        raise ValueError("weight image CRC32 does not match manifest")


def profile_is_rank_eligible(profile: dict, target: str) -> bool:
    return (
        profile.get("validated") is True
        and profile.get("profile") == "egfr_admet_v1"
        and str(target).upper() == "EGFR"
        and profile.get("target", {}).get("name") == "EGFR"
    )


def _u16(value: int) -> int:
    return value & 0xFFFF


def _set_adjacency_bit(words: list[int], row: int, column: int) -> None:
    index = row * MAX_NODES + column
    words[index // 32] |= 1 << (index % 32)


def encode_graph(smiles: str, profile: dict) -> dict[str, object]:
    """Encode a molecule with virtual node zero for the programmed GNN."""
    from rdkit import Chem

    molecule = Chem.MolFromSmiles(smiles)
    if molecule is None:
        raise ValueError(f"invalid SMILES: {smiles}")
    real_atom_count = molecule.GetNumAtoms()
    if real_atom_count > MAX_REAL_ATOMS:
        raise ValueError(
            f"molecule has {real_atom_count} atoms; 49-atom profile limit exceeded"
        )

    adjacency_words = [0] * ADJACENCY_WORDS
    features = [0] * (MAX_NODES * FEATURE_DIM)
    features[FEATURE_DIM - 1] = Q8_SCALE
    for atom in molecule.GetAtoms():
        node = atom.GetIdx() + 1
        _set_adjacency_bit(adjacency_words, 0, node)
        _set_adjacency_bit(adjacency_words, node, 0)
        _set_adjacency_bit(adjacency_words, node, node)
        base = node * FEATURE_DIM
        features[base + min(31, max(0, atom.GetAtomicNum() - 1))] = Q8_SCALE
        features[base + 32 + min(5, atom.GetDegree())] = Q8_SCALE
        features[base + 38 + min(4, max(0, atom.GetFormalCharge() + 2))] = Q8_SCALE
        features[base + 43] = Q8_SCALE if atom.GetIsAromatic() else 0
    for bond in molecule.GetBonds():
        begin, end = bond.GetBeginAtomIdx() + 1, bond.GetEndAtomIdx() + 1
        _set_adjacency_bit(adjacency_words, begin, end)
        _set_adjacency_bit(adjacency_words, end, begin)
    feature_words = [
        _u16(features[index]) | (_u16(features[index + 1]) << 16)
        for index in range(0, len(features), 2)
    ]
    return {
        "canonical_smiles": Chem.MolToSmiles(molecule),
        "real_atom_count": real_atom_count,
        "node_count": real_atom_count + 1,
        "adjacency_words": adjacency_words,
        "feature_words": feature_words,
    }


def encode_descriptors(smiles: str, profile: dict) -> list[int]:
    """Return the 20 manifest-ordered, normalized Q8.8 descriptor values."""
    from rdkit import Chem
    from rdkit.Chem import Descriptors

    molecule = Chem.MolFromSmiles(smiles)
    if molecule is None:
        raise ValueError(f"invalid SMILES: {smiles}")
    _validate_profile(profile)
    values = []
    for descriptor in profile["descriptors"]:
        try:
            function = getattr(Descriptors, descriptor["name"])
        except AttributeError as exc:
            raise ValueError(f"unknown RDKit descriptor: {descriptor['name']}") from exc
        value = float(function(molecule))
        if not math.isfinite(value):
            value = 0.0
        values.append(q8((value - float(descriptor["center"])) / float(descriptor["scale"])))
    return values


def hardware_score(evaluation: dict) -> float | None:
    """Return the 0-100 score for a fully rank-eligible EGFR FPGA result."""
    if not isinstance(evaluation, dict) or not (
        evaluation.get("ranking_eligible") is True
        and evaluation.get("status") == "hardware_complete"
        and evaluation.get("model_profile") == "egfr_admet_v1"
    ):
        return None
    try:
        gnn = float(evaluation["gnn"]["egfr_activity_score"])
        tanimoto = float(evaluation["tanimoto"]["similarity"])
        admet = evaluation["admet"]
        oral = float(admet["oral_bioavailability"])
        bbb = float(admet["bbb_permeability"])
        lipophilicity = float(admet["lipophilicity_desirability"])
        herg = float(admet["herg_block_risk"])
    except (KeyError, TypeError, ValueError):
        return None
    values = (gnn, tanimoto, oral, bbb, lipophilicity, herg)
    if not all(math.isfinite(value) and 0.0 <= value <= 1.0 for value in values):
        return None
    return 100.0 * (
        0.35 * gnn + 0.20 * tanimoto + 0.15 * oral + 0.10 * bbb
        + 0.10 * lipophilicity + 0.10 * (1.0 - herg)
    )
