import json
import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from agents.fpga_client import FPGAClient
from agents.generator import GeneratorAgent


PROFILE_DIR = Path(__file__).resolve().parent / "models" / "fpga" / "egfr_admet_v1"


class FakeFPGAClient(FPGAClient):
    def __init__(self):
        super().__init__(host="board", port=5001, service_url="http://board", enabled=True)
        self.calls = []
        self.tanimoto_calls = 0

    def _request_words(self, task_id, payload, batch_size):
        self.calls.append((task_id, payload, batch_size))
        if task_id == self.TASK_TANIMOTO:
            result = 0x10000 if self.tanimoto_calls == 0 else 0x8000
            self.tanimoto_calls += 1
            return (result,), self.tanimoto_calls, 0.001
        if task_id == self.TASK_GNN:
            return tuple(0x00000100 + index for index in range(batch_size)), 2, 0.002
        if task_id == self.TASK_ADMET:
            return tuple(128 + index for index in range(batch_size * 4)), 3, 0.003
        if task_id == self.TASK_RELOAD:
            return (7,), 4, 0.004
        raise AssertionError(task_id)


class MoleculeEncodingTests(unittest.TestCase):
    def test_real_smiles_is_encoded_to_exact_hardware_shapes(self):
        client = FPGAClient(enabled=False)
        encoded = client.encode_molecule("CCO")

        self.assertEqual(32, len(encoded["fingerprint_words"]))
        self.assertEqual(79, len(encoded["adjacency_words"]))
        self.assertEqual(1600, len(encoded["feature_words"]))
        self.assertEqual(20, len(encoded["descriptor_words"]))

        # Row-major adjacency, LSB first: atom 0 has self-loop and bond to atom 1.
        self.assertEqual(1, (encoded["adjacency_words"][0] >> 0) & 1)
        self.assertEqual(1, (encoded["adjacency_words"][0] >> 1) & 1)
        # Carbon atomic-number one-hot feature index 5 is the high half of word 2.
        self.assertEqual(0x0100, (encoded["feature_words"][2] >> 16) & 0xFFFF)

    def test_more_than_fifty_atoms_is_rejected(self):
        client = FPGAClient(enabled=False)
        with self.assertRaisesRegex(ValueError, "50"):
            client.encode_molecule("C" * 51)


class HardwareBatchEvaluationTests(unittest.TestCase):
    def test_pair_similarity_uses_the_tanimoto_accelerator(self):
        client = FakeFPGAClient()

        result = client.compute_tanimoto_smiles("CCO", "CCO")

        task_id, payload, batch_size = client.calls[0]
        self.assertEqual(client.TASK_TANIMOTO, task_id)
        self.assertEqual(64 * 4, len(payload))
        self.assertEqual(1, batch_size)
        self.assertEqual(1.0, result["similarity"])
        self.assertEqual(0x10000, result["raw_q16_16"])
        self.assertTrue(result["accelerated"])

    def test_three_real_hardware_tasks_are_batched_and_mapped_to_candidates(self):
        client = FakeFPGAClient()
        client.reload_model()
        molecules = [
            {"id": "a", "smiles": "CCO"},
            {"id": "b", "smiles": "CCN"},
        ]

        summary = client.evaluate_molecules(molecules)

        self.assertEqual("hardware_complete", summary["status"])
        # The programmed RTL's shared-query Tanimoto mode drops words while
        # the core is busy. Pair mode is exact; GNN and ADMET stay batched.
        self.assertEqual([0xFE, 0, 0, 1, 2], [call[0] for call in client.calls])
        self.assertEqual([1, 1, 1, 2, 2], [call[2] for call in client.calls])
        self.assertEqual(18152, len(client.calls[0][1]))
        self.assertEqual(64 * 4, len(client.calls[1][1]))
        self.assertEqual(64 * 4, len(client.calls[2][1]))
        self.assertEqual(1679 * 2 * 4, len(client.calls[3][1]))
        self.assertEqual(20 * 2 * 4, len(client.calls[4][1]))

        first = molecules[0]["fpga_evaluation"]
        second = molecules[1]["fpga_evaluation"]
        self.assertTrue(first["accelerated"])
        self.assertEqual(1.0, first["tanimoto"]["similarity"])
        self.assertEqual(0.5, second["tanimoto"]["similarity"])
        self.assertEqual(1.0, first["gnn"]["node0_hidden0"])
        self.assertEqual([0.5, 0.503906, 0.507812, 0.511719], first["admet"]["predictions"])
        self.assertEqual("egfr_admet_v1", first["model_profile"])
        self.assertTrue(first["ranking_eligible"])

    def test_invalid_candidate_does_not_block_valid_candidate(self):
        client = FakeFPGAClient()
        molecules = [
            {"id": "bad", "smiles": "not-smiles"},
            {"id": "good", "smiles": "CCO"},
        ]

        summary = client.evaluate_molecules(molecules)

        self.assertEqual(1, summary["accelerated_count"])
        self.assertEqual("not_encodable", molecules[0]["fpga_evaluation"]["status"])
        self.assertEqual("hardware_complete", molecules[1]["fpga_evaluation"]["status"])

    def test_reference_is_manifest_ligand_not_first_candidate(self):
        client = FakeFPGAClient()
        profile = json.loads((PROFILE_DIR / "manifest.json").read_text(encoding="utf-8"))
        client.reload_model()

        summary = client.evaluate_molecules([{"id": "a", "smiles": "CCO"}], target="EGFR")

        self.assertEqual(profile["target"]["reference_smiles"], summary["reference_smiles"])

    def test_reload_accepts_one_epoch_word(self):
        client = FakeFPGAClient()

        result = client.reload_model()

        self.assertEqual("egfr_admet_v1", result["model_profile"])
        self.assertGreaterEqual(result["epoch"], 1)
        self.assertTrue(result["ranking_eligible"])
        self.assertEqual((0xFE, 1, 18152),
                         (client.calls[0][0], client.calls[0][2], len(client.calls[0][1])))

    def test_manifest_outputs_are_named_without_removing_raw_outputs(self):
        client = FakeFPGAClient()
        client.reload_model()
        molecules = [{"id": "a", "smiles": "CCO"}]

        client.evaluate_molecules(molecules, target="EGFR")

        evaluation = molecules[0]["fpga_evaluation"]
        self.assertEqual(1.0, evaluation["gnn"]["egfr_activity_score"])
        self.assertIn("raw_output_word", evaluation["gnn"])
        self.assertEqual(0.5, evaluation["admet"]["lipophilicity"])
        self.assertEqual(0.5, evaluation["admet"]["lipophilicity_desirability"])
        self.assertEqual(0.503906, evaluation["admet"]["oral_bioavailability"])
        self.assertIn("raw_q8_8", evaluation["admet"])

    def test_profile_accepts_forty_nine_real_atoms_and_rejects_fifty(self):
        client = FakeFPGAClient()
        client.reload_model()
        molecules = [
            {"id": "fits", "smiles": "C" * 49},
            {"id": "too-large", "smiles": "C" * 50},
        ]

        client.evaluate_molecules(molecules, target="EGFR")

        self.assertEqual(50, molecules[0]["fpga_evaluation"]["node_count"])
        self.assertEqual("not_encodable", molecules[1]["fpga_evaluation"]["status"])
        self.assertIn("49-atom", molecules[1]["fpga_evaluation"]["error"])

    def test_target_mismatch_does_not_send_egfr_profile_inputs(self):
        client = FakeFPGAClient()
        client.reload_model()
        client.calls.clear()
        molecules = [{"id": "a", "smiles": "CCO"}]

        summary = client.evaluate_molecules(molecules, target="ERBB2")

        self.assertEqual("target_mismatch", summary["status"])
        self.assertFalse(molecules[0]["fpga_evaluation"]["ranking_eligible"])
        self.assertEqual([], client.calls)

    def test_missing_profile_falls_back_without_hardware_request(self):
        with patch.dict(os.environ, {"FPGA_MODEL_DIR": "does-not-exist"}):
            client = FakeFPGAClient()
        molecules = [{"id": "a", "smiles": "CCO"}]

        summary = client.evaluate_molecules(molecules, target="EGFR")

        self.assertEqual("profile_unavailable", summary["status"])
        self.assertIsNone(summary["model_profile"])
        self.assertFalse(molecules[0]["fpga_evaluation"]["ranking_eligible"])
        self.assertEqual([], client.calls)

    def test_crc_valid_malformed_profile_falls_back_without_hardware_request(self):
        profile = json.loads((PROFILE_DIR / "manifest.json").read_text(encoding="utf-8"))
        del profile["target"]["reference_smiles"]
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "manifest.json").write_text(json.dumps(profile), encoding="utf-8")
            (package / "weights.bin").write_bytes((PROFILE_DIR / "weights.bin").read_bytes())
            with patch.dict(os.environ, {"FPGA_MODEL_DIR": directory}):
                client = FakeFPGAClient()
            molecules = [{"id": "a", "smiles": "CCO"}]

            summary = client.evaluate_molecules(molecules, target="EGFR")

        self.assertEqual("profile_unavailable", summary["status"])
        self.assertIsNone(summary["model_profile"])
        self.assertFalse(molecules[0]["fpga_evaluation"]["ranking_eligible"])
        self.assertEqual([], client.calls)

    def test_transport_fallback_is_explicitly_rank_ineligible(self):
        client = FakeFPGAClient()
        client.reload_model()
        request_words = client._request_words

        def fail_gnn(task_id, payload, batch_size):
            if task_id == client.TASK_GNN:
                raise OSError("board disconnected")
            return request_words(task_id, payload, batch_size)

        molecules = [{"id": "a", "smiles": "CCO"}, {"id": "b", "smiles": "CCN"}]
        with patch.object(client, "_request_words", side_effect=fail_gnn):
            summary = client.evaluate_molecules(molecules, target="EGFR")

        self.assertEqual("fallback", summary["status"])
        self.assertEqual("egfr_admet_v1", summary["model_profile"])
        self.assertFalse(summary["ranking_eligible"])
        for molecule in molecules:
            evaluation = molecule["fpga_evaluation"]
            self.assertEqual("fallback", evaluation["status"])
            self.assertEqual("egfr_admet_v1", evaluation["model_profile"])
            self.assertFalse(evaluation["ranking_eligible"])
            self.assertEqual("ineligible", evaluation["ranking_effect"])


class OrchestratorIntegrationTests(unittest.TestCase):
    def test_swagger_placeholder_target_defaults_to_egfr(self):
        from agents.orchestrator import orchestrator

        with patch("agents.orchestrator.fpga_client.evaluate_molecules", return_value={"status": "disabled"}):
            result = orchestrator.run_pipeline({
                "name": "test",
                "target": "string",
                "target_protein": "string",
                "research_field": "drug discovery",
                "experience_level": "intermediate",
            })

        self.assertEqual("EGFR", result["summary"]["target"])
        self.assertEqual("EGFR", result["steps"]["generator"]["result"]["target"])

    def test_pipeline_passes_generated_real_smiles_to_fpga_evaluator(self):
        from agents.orchestrator import orchestrator

        def attach(molecules, target):
            for molecule in molecules:
                molecule["fpga_evaluation"] = {"status": "hardware_complete"}
            return {"status": "hardware_complete", "accelerated_count": len(molecules)}

        with patch("agents.orchestrator.fpga_client.evaluate_molecules", side_effect=attach) as evaluate:
            result = orchestrator.run_pipeline({
                "name": "test",
                "target_protein": "EGFR",
                "research_field": "drug discovery",
                "experience_level": "intermediate",
            })

        generated = result["steps"]["generator"]["result"]
        evaluate.assert_called_once_with(generated["generated_molecules"], target="EGFR")
        self.assertEqual("hardware_complete", generated["fpga_batch"]["status"])
        self.assertTrue(all("fpga_evaluation" in item for item in generated["generated_molecules"]))


class CandidateGenerationTests(unittest.TestCase):
    def test_known_drugs_can_fill_five_default_candidates(self):
        generator = GeneratorAgent()
        request = {
            "target_protein": "EGFR",
            "count": 5,
            "constraints": {"min_molwt": 200, "max_molwt": 600, "min_qed": 0.3},
        }

        with patch.object(generator, "_mutate_molecule", side_effect=lambda mol: mol), \
                patch.object(generator, "_build_from_fragments", return_value=None):
            result = generator.generate(request)

        self.assertEqual(5, result["total_generated"])
        self.assertEqual(5, len({item["smiles"] for item in result["generated_molecules"]}))


if __name__ == "__main__":
    unittest.main()
