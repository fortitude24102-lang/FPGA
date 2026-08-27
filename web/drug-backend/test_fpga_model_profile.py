import json
import math
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

import numpy

from agents.fpga_model import (
    WEIGHT_BYTES,
    encode_descriptors,
    encode_graph,
    hardware_score,
    load_profile,
    profile_is_rank_eligible,
    q8,
    validate_weight_image,
)
from tools.train_fpga_models import (
    admet_fixed_point_drift,
    emulate_q8_admet,
    emulate_q8_graph,
    fetch_chembl_egfr,
    fetch_tdc_dataset,
    pack_weight_image,
    scaffold_key,
    scaffold_split,
    sigmoid_q8,
    train_admet,
    train_gnn_activity,
    write_package,
    _descriptor_rows,
    _q8_array,
)


DESCRIPTORS = [
    {"name": "NumHAcceptors", "center": 0.0, "scale": 1.0},
    {"name": "NumHDonors", "center": 1.0, "scale": 1.0},
    {"name": "MolWt", "center": 46.069, "scale": 1.0},
] + [{"name": "HeavyAtomCount", "center": 3.0, "scale": 1.0}] * 17


def profile_with_descriptors():
    return {
        "profile": "egfr_admet_v1",
        "validated": True,
        "target": {"name": "EGFR", "reference_smiles": "CCO"},
        "weights": {"bytes": WEIGHT_BYTES, "crc32": "00000000"},
        "descriptors": DESCRIPTORS,
        "outputs": {
            "gnn": ["egfr_activity_score", "egfr_activity_trace"],
            "admet": [
                "lipophilicity_desirability", "oral_bioavailability",
                "herg_block_risk", "bbb_permeability",
            ],
        },
    }


def adjacency_bit(words, row, column):
    index = row * 50 + column
    return (words[index // 32] >> (index % 32)) & 1


def feature_halfword(words, node, feature):
    index = node * 64 + feature
    return (words[index // 2] >> (16 * (index % 2))) & 0xFFFF


class ProfileTests(unittest.TestCase):
    def test_profile_rejects_wrong_weight_length(self):
        profile = {
            "profile": "egfr_admet_v1",
            "validated": True,
            "target": {"name": "EGFR"},
            "weights": {"bytes": 18152, "crc32": "00000000"},
        }
        with self.assertRaisesRegex(ValueError, "18152"):
            validate_weight_image(profile, b"\x00" * 32)

    def test_only_validated_egfr_profile_is_rank_eligible(self):
        profile = {
            "profile": "egfr_admet_v1",
            "validated": True,
            "target": {"name": "EGFR"},
        }
        self.assertTrue(profile_is_rank_eligible(profile, "EGFR"))
        self.assertFalse(profile_is_rank_eligible(profile, "ALK"))

    def test_load_profile_reads_manifest(self):
        profile = profile_with_descriptors()
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "manifest.json").write_text(json.dumps(profile), encoding="utf-8")
            self.assertEqual(profile, load_profile(Path(directory)))

    def test_load_profile_rejects_missing_reference_or_wrong_output_contract(self):
        invalid_profiles = []
        missing_reference = profile_with_descriptors()
        del missing_reference["target"]["reference_smiles"]
        invalid_profiles.append(missing_reference)
        wrong_outputs = profile_with_descriptors()
        wrong_outputs["outputs"]["admet"][-1] = "wrong_name"
        invalid_profiles.append(wrong_outputs)

        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory, "manifest.json")
            for profile in invalid_profiles:
                manifest.write_text(json.dumps(profile), encoding="utf-8")
                with self.assertRaises(ValueError):
                    load_profile(Path(directory))

    def test_weight_image_requires_manifest_crc(self):
        image = b"\x00" * WEIGHT_BYTES
        profile = profile_with_descriptors()
        profile["weights"]["crc32"] = f"{zlib.crc32(image) & 0xffffffff:08x}"
        validate_weight_image(profile, image)
        profile["weights"]["crc32"] = "00000000"
        with self.assertRaisesRegex(ValueError, "CRC32"):
            validate_weight_image(profile, image)


class EncodingTests(unittest.TestCase):
    def test_graph_uses_virtual_node_and_exact_hardware_shapes(self):
        encoded = encode_graph("CO", profile_with_descriptors())

        self.assertEqual(79, len(encoded["adjacency_words"]))
        self.assertEqual(1600, len(encoded["feature_words"]))
        self.assertEqual(2, encoded["real_atom_count"])
        self.assertEqual(3, encoded["node_count"])
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 0, 1))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 1, 0))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 0, 2))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 2, 0))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 1, 1))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 2, 2))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 1, 2))
        self.assertEqual(1, adjacency_bit(encoded["adjacency_words"], 2, 1))
        self.assertEqual(256, feature_halfword(encoded["feature_words"], 0, 63))
        self.assertEqual(256, feature_halfword(encoded["feature_words"], 1, 5))

    def test_descriptor_encoding_obeys_manifest_order_and_normalization(self):
        descriptors = encode_descriptors("CCO", profile_with_descriptors())

        self.assertEqual(20, len(descriptors))
        self.assertEqual([256, 0, 0], descriptors[:3])

    def test_q8_saturates_signed_fixed_point_values(self):
        self.assertEqual(128, q8(0.5))
        self.assertEqual(32767, q8(200.0))
        self.assertEqual(-32768, q8(-200.0))

    def test_fifty_real_atoms_exceed_the_profile_limit(self):
        with self.assertRaisesRegex(ValueError, "49-atom profile limit"):
            encode_graph("C" * 50, profile_with_descriptors())


class FixedPointTests(unittest.TestCase):
    def test_drift_uses_retained_full_precision_logistic_reference(self):
        """Replacing this reference with the RTL interpolation makes drift falsely zero."""
        full_parameters = [
            numpy.array([[1.0] + [0.0] * 9] + [[0.0] * 10] * 19),
            numpy.zeros(10), numpy.array([2.0] + [0.0] * 9), numpy.zeros(1),
        ]
        quantized = {
            "hidden_weights": numpy.array([256] + [0] * 199, dtype=numpy.int16),
            "hidden_biases": numpy.zeros(10, dtype=numpy.int16),
            "output_weights": numpy.array([512] + [0] * 9, dtype=numpy.int16),
            "output_bias": numpy.zeros(1, dtype=numpy.int16),
        }

        drift = admet_fixed_point_drift(
            numpy.array([[1.0] + [0.0] * 19]), full_parameters,
            numpy.array([[256] + [0] * 19]), quantized,
        )

        self.assertAlmostEqual(abs(1 / (1 + math.exp(-2)) - 226 / 256), drift, places=10)

    def test_weight_image_matches_existing_protocol_order(self):
        gnn = numpy.zeros(8192, dtype=numpy.int16)
        gnn[0:3] = (1, -2, 3)
        admet = []
        for value in range(4):
            admet.append({
                "hidden_weights": numpy.full(200, value + 10, dtype=numpy.int16),
                "hidden_biases": numpy.full(10, value + 20, dtype=numpy.int16),
                "output_weights": numpy.full(10, value + 30, dtype=numpy.int16),
                "output_bias": numpy.array([value + 40], dtype=numpy.int16),
            })

        image = pack_weight_image(gnn, admet)
        values = struct.unpack("<9076h", image)

        self.assertEqual(tuple(gnn), values[:8192])
        self.assertEqual((10, 10, 10), values[8192:8195])
        self.assertEqual(40, values[8192 + 220])
        self.assertEqual(18152, len(image))

    def test_piecewise_sigmoid_matches_rtl_knots(self):
        self.assertEqual(
            [0, 5, 30, 69, 128, 187, 226, 251, 256],
            [sigmoid_q8(x) for x in (-2048, -1024, -512, -256, 0, 256, 512, 1024, 2048)],
        )

    def test_admet_emulator_uses_arithmetic_shift_relu_and_sigmoid(self):
        parameters = {
            "hidden_weights": numpy.zeros(200, dtype=numpy.int16),
            "hidden_biases": numpy.zeros(10, dtype=numpy.int16),
            "output_weights": numpy.zeros(10, dtype=numpy.int16),
            "output_bias": numpy.array([0], dtype=numpy.int16),
        }
        parameters["hidden_weights"][0] = 256
        parameters["hidden_weights"][1] = -256
        parameters["output_weights"][:2] = 256

        self.assertEqual(187 / 256, emulate_q8_admet([256] + [0] * 19, parameters))

    def test_graph_emulator_uses_feature_major_weight_order(self):
        encoded = encode_graph("C", profile_with_descriptors())
        weights = numpy.zeros(8192, dtype=numpy.int16)
        weights[5 * 128] = 128
        weights[5 * 128 + 1] = 256

        self.assertEqual((0.5, 1.0), emulate_q8_graph(encoded, weights))


class TrainingTests(unittest.TestCase):
    def test_trainer_reports_drift_from_retained_standard_sigmoid_parameters(self):
        import pandas as pd

        frame = pd.DataFrame({
            "Drug": ["CCO", "CCN", "CCC", "CCCl", "CCBr", "COC", "CNC", "CC=O"],
            "Y": [0, 1, 0, 1, 0, 1, 0, 1],
        })
        split = {"train": frame.iloc[:4], "validation": frame.iloc[4:6], "test": frame.iloc[6:]}
        model = train_admet(split, "bbb", 20260826)
        raw_test, _, _ = _descriptor_rows(split["test"])
        normalized_test = numpy.clip((raw_test - model["descriptor_center"]) / model["descriptor_scale"], -8, 8)

        recomputed = admet_fixed_point_drift(
            normalized_test, model["float_parameters"], _q8_array(normalized_test), model,
        )

        self.assertGreater(recomputed, 0.0)
        self.assertEqual(round(recomputed, 6), model["max_fixed_point_drift"])

    def test_compact_trainers_are_deterministic_and_hardware_shaped(self):
        import pandas as pd

        frame = pd.DataFrame({
            "Drug": ["CCO", "CCN", "CCC", "CCCl", "CCBr", "COC", "CNC", "CC=O"],
            "Y": [0, 1, 0, 1, 0, 1, 0, 1],
        })
        split = {"train": frame.iloc[:4], "validation": frame.iloc[4:6], "test": frame.iloc[6:]}

        first = train_admet(split, "bbb", 20260826)
        second = train_admet(split, "bbb", 20260826)
        gnn = train_gnn_activity(split, 20260826)

        self.assertTrue(numpy.array_equal(first["hidden_weights"], second["hidden_weights"]))
        self.assertEqual((200, 10, 10, 1), tuple(first[name].size for name in (
            "hidden_weights", "hidden_biases", "output_weights", "output_bias")))
        self.assertEqual(8192, gnn["weights"].size)
        self.assertTrue(numpy.any(gnn["float_weights"] != gnn["weights"] / 256))
        self.assertTrue(any(not numpy.array_equal(full, deployed) for full, deployed in zip(
            first["float_parameters"],
            (first["hidden_weights"].reshape(20, 10) / 256, first["hidden_biases"] / 256,
             first["output_weights"] / 256, first["output_bias"] / 256),
        )))
        self.assertIn("balanced_accuracy", first["metrics"])
        self.assertIn("rmse", gnn["metrics"])

    def test_gnn_trainer_is_standalone_from_runtime_agents_package(self):
        import builtins
        import pandas as pd

        frame = pd.DataFrame({"Drug": ["CCO", "CCN", "CCC"], "Y": [0.2, 0.5, 0.8]})
        split = {"train": frame, "validation": frame, "test": frame}
        real_import = builtins.__import__

        def standalone_import(name, *args, **kwargs):
            if name == "agents.fpga_model":
                raise ModuleNotFoundError("standalone tools path")
            return real_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=standalone_import):
            self.assertEqual(8192, train_gnn_activity(split, 20260826)["weights"].size)

    def test_write_package_records_real_length_crc_and_manifest_contract(self):
        gnn = {"weights": numpy.zeros(8192, dtype=numpy.int16)}
        model = {
            "hidden_weights": numpy.zeros(200, dtype=numpy.int16),
            "hidden_biases": numpy.zeros(10, dtype=numpy.int16),
            "output_weights": numpy.zeros(10, dtype=numpy.int16),
            "output_bias": numpy.zeros(1, dtype=numpy.int16),
        }
        metadata = profile_with_descriptors() | {"validated": False}
        with tempfile.TemporaryDirectory() as directory:
            manifest_path, weights_path = write_package(
                Path(directory), {"gnn": gnn, "admet": [model] * 4}, metadata
            )
            image = weights_path.read_bytes()
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(18152, len(image))
        self.assertEqual(18152, manifest["weights"]["bytes"])
        self.assertEqual(f"{zlib.crc32(image) & 0xffffffff:08x}", manifest["weights"]["crc32"])


class HardwareScoreTests(unittest.TestCase):
    def test_rank_eligible_hardware_result_has_weighted_score(self):
        evaluation = {
            "status": "hardware_complete",
            "model_profile": "egfr_admet_v1",
            "ranking_eligible": True,
            "gnn": {"egfr_activity_score": 1.0},
            "tanimoto": {"similarity": 1.0},
            "admet": {
                "lipophilicity_desirability": 1.0,
                "oral_bioavailability": 1.0,
                "herg_block_risk": 0.0,
                "bbb_permeability": 1.0,
            },
        }
        self.assertEqual(100.0, hardware_score(evaluation))

    def test_ineligible_hardware_result_has_no_score(self):
        self.assertIsNone(hardware_score({"ranking_eligible": False}))


class _FixtureResponse:
    def __init__(self, body):
        self.body = body.encode("utf-8")

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class DatasetTests(unittest.TestCase):
    def test_chembl_paginates_canonicalizes_and_median_reduces(self):
        pages = iter((
            '{"activities": [{"canonical_smiles": "Cc1ccccc1", "pchembl_value": "7.0"}, {"canonical_smiles": "not-a-smiles", "pchembl_value": "8.0"}], "page_meta": {"next": "/chembl/api/data/activity.json?page=2"}}',
            '{"activities": [{"canonical_smiles": "c1ccccc1C", "pchembl_value": "9.0"}, {"canonical_smiles": "CCO", "pchembl_value": "NaN"}], "page_meta": {"next": null}}',
        ))
        with tempfile.TemporaryDirectory() as directory, patch(
            "tools.train_fpga_models.urlopen", side_effect=lambda *_, **__: _FixtureResponse(next(pages))
        ):
            frame = fetch_chembl_egfr(Path(directory))

        self.assertEqual(["Cc1ccccc1"], frame.Drug.tolist())
        self.assertEqual([8.0], frame.Y.tolist())

    def test_chembl_reuses_a_nonempty_cache_without_http(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "chembl_egfr.csv"
            cache.write_text("Drug,Y\nCCO,6.5\n", encoding="utf-8")
            with patch("tools.train_fpga_models.urlopen", side_effect=AssertionError("network used")):
                frame = fetch_chembl_egfr(Path(directory))

        self.assertEqual(["CCO"], frame.Drug.tolist())
        self.assertEqual([6.5], frame.Y.tolist())

    def test_tdc_normalizes_tsv_and_reuses_cache(self):
        with tempfile.TemporaryDirectory() as directory, patch(
            "tools.train_fpga_models.urlopen",
            return_value=_FixtureResponse("Drug_ID\tDrug\tY\nA\tCCO\t1.2\n"),
        ):
            frame = fetch_tdc_dataset("Lipophilicity_AstraZeneca", Path(directory))
            with patch("tools.train_fpga_models.urlopen", side_effect=AssertionError("network used")):
                cached = fetch_tdc_dataset("Lipophilicity_AstraZeneca", Path(directory))

        self.assertEqual(["Drug", "Y"], frame.columns.tolist())
        self.assertEqual(["CCO"], cached.Drug.tolist())
        self.assertEqual([1.2], cached.Y.tolist())

    def test_tdc_request_identifies_the_training_client(self):
        def respond(request, **_):
            self.assertIn("MolRecommender", request.get_header("User-agent"))
            return _FixtureResponse("Drug\tY\nCCO\t1\n")

        with tempfile.TemporaryDirectory() as directory, patch(
            "tools.train_fpga_models.urlopen", side_effect=respond
        ):
            fetch_tdc_dataset("BBB_Martins", Path(directory))

    def test_scaffold_split_never_leaks_a_scaffold(self):
        import pandas as pd

        frame = pd.DataFrame({
            "Drug": ["Cc1ccccc1", "Oc1ccccc1", "C1CCCCC1", "CCO", "CCN", ""],
            "Y": [1.0, 0.8, 0.4, 0.2, 0.1, 9.0],
        })
        split = scaffold_split(frame, seed=20260826)
        scaffolds = [set(map(scaffold_key, split[name].Drug)) for name in ("train", "validation", "test")]

        self.assertFalse(scaffolds[0] & scaffolds[1])
        self.assertFalse(scaffolds[0] & scaffolds[2])
        self.assertFalse(scaffolds[1] & scaffolds[2])
        self.assertEqual(1, split["train"].attrs["discarded_invalid_count"])


if __name__ == "__main__":
    unittest.main()
