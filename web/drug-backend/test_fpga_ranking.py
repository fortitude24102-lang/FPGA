import copy
import unittest

from agents.reviewer import ReviewerAgent


class FpgaRankingTests(unittest.TestCase):
    def test_valid_hardware_score_can_change_candidate_order(self):
        properties = {
            "lipinski_violations": 0, "lipinski_pass": True, "qed": 0.7,
            "sa_score": 3.0, "molwt": 400.0, "logp": 2.0, "tpsa": 80.0,
        }
        low = {
            "id": "baseline_favored", "smiles": "CCO", "properties": properties,
            "fpga_evaluation": {
                "status": "hardware_complete", "model_profile": "egfr_admet_v1",
                "ranking_effect": "eligible", "ranking_eligible": True,
                "gnn": {"egfr_activity_score": 0.1},
                "tanimoto": {"similarity": 0.1},
                "admet": {
                    "lipophilicity_desirability": 0.2,
                    "oral_bioavailability": 0.1,
                    "herg_block_risk": 0.9,
                    "bbb_permeability": 0.1,
                },
            },
        }
        high = copy.deepcopy(low)
        high["id"], high["smiles"] = "hardware_favored", "CCN"
        high["fpga_evaluation"]["gnn"]["egfr_activity_score"] = 0.95
        high["fpga_evaluation"]["tanimoto"]["similarity"] = 0.9
        high["fpga_evaluation"]["admet"] = {
            "lipophilicity_desirability": 0.9, "oral_bioavailability": 0.9,
            "herg_block_risk": 0.05, "bbb_permeability": 0.9,
        }

        result = ReviewerAgent().review({"generated_molecules": [low, high]})

        self.assertEqual("hardware_favored", result["top_candidates"][0]["id"])
        self.assertAlmostEqual(86.125, result["top_candidates"][0]["total_score"])
        self.assertIn("fpga_hardware", result["top_candidates"][0]["score_breakdown"])
        self.assertEqual(
            "blended_30_percent", result["top_candidates"][0]["ranking_effect"]
        )

    def test_ineligible_hardware_keeps_baseline_scores(self):
        molecule = {
            "id": "candidate", "smiles": "CCO",
            "properties": {
                "lipinski_violations": 0, "lipinski_pass": True,
                "qed": 0.7, "sa_score": 3.0, "molwt": 400.0,
                "logp": 2.0, "tpsa": 80.0,
            },
        }
        peer = copy.deepcopy(molecule)
        peer["id"] = "baseline_peer"
        peer["properties"]["qed"] = 0.9
        baseline = ReviewerAgent().review({"generated_molecules": [molecule, peer]})
        demo = copy.deepcopy(molecule)
        demo["fpga_evaluation"] = {
            "status": "hardware_complete", "model_profile": "deterministic_demo_q8_8",
            "ranking_effect": "ineligible", "ranking_eligible": False,
        }

        fallback = ReviewerAgent().review({"generated_molecules": [demo, peer]})

        self.assertEqual(
            [(item["id"], item["total_score"]) for item in baseline["scoring_details"]],
            [(item["id"], item["total_score"]) for item in fallback["scoring_details"]],
        )
        self.assertNotIn("fpga_hardware", fallback["scoring_details"][1]["breakdown"])

    def test_malformed_eligible_hardware_keeps_baseline_scores(self):
        molecule = {
            "id": "candidate", "smiles": "CCO",
            "properties": {
                "lipinski_violations": 0, "lipinski_pass": True,
                "qed": 0.7, "sa_score": 3.0, "molwt": 400.0,
                "logp": 2.0, "tpsa": 80.0,
            },
        }
        baseline = ReviewerAgent().review({"generated_molecules": [molecule]})
        malformed = copy.deepcopy(molecule)
        malformed["fpga_evaluation"] = {
            "status": "hardware_complete", "model_profile": "egfr_admet_v1",
            "ranking_eligible": True, "gnn": {"egfr_activity_score": 2.0},
        }

        fallback = ReviewerAgent().review({"generated_molecules": [malformed]})

        self.assertEqual(
            baseline["scoring_details"][0]["total_score"],
            fallback["scoring_details"][0]["total_score"],
        )
        self.assertNotIn("fpga_hardware", fallback["scoring_details"][0]["breakdown"])

    def test_disabled_or_failed_hardware_keeps_baseline_scores(self):
        molecule = {
            "id": "candidate", "smiles": "CCO",
            "properties": {
                "lipinski_violations": 0, "lipinski_pass": True,
                "qed": 0.7, "sa_score": 3.0, "molwt": 400.0,
                "logp": 2.0, "tpsa": 80.0,
            },
        }
        peer = copy.deepcopy(molecule)
        peer["id"] = "baseline_peer"
        peer["properties"]["qed"] = 0.9
        baseline = ReviewerAgent().review({"generated_molecules": [molecule, peer]})

        for status in ("disabled", "fallback", "failed"):
            with self.subTest(status=status):
                fallback = copy.deepcopy(molecule)
                fallback["fpga_evaluation"] = {
                    "status": status, "ranking_eligible": False,
                    "ranking_effect": "ineligible",
                }
                result = ReviewerAgent().review({"generated_molecules": [fallback, peer]})

                self.assertEqual(
                    [(item["id"], item["total_score"]) for item in baseline["scoring_details"]],
                    [(item["id"], item["total_score"]) for item in result["scoring_details"]],
                )
                self.assertNotIn(
                    "fpga_hardware", result["scoring_details"][1]["breakdown"]
                )
