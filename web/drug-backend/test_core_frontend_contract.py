import asyncio
import copy
import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from main import (
    DebateRespondRequest,
    DebateRound,
    DebateSession,
    ResearcherProfile,
    app,
    orchestrator,
    run_pipeline,
    v32_debate_respond,
    v32_start_debate,
    DebateStartRequest,
)


class CoreFrontendContractTest(unittest.TestCase):
    @staticmethod
    def _frontend_profile():
        return ResearcherProfile(
            researcher_id="researcher-demo-001",
            name="Demo Researcher",
            background="药物化学",
            experience_years=2,
            target="EGFR",
            research_goal="提高选择性",
            constraints=["logP < 5"],
            skills={"化学信息学": 68},
        )

    def _run_pipeline(self, fpga_evaluation):
        def attach_evaluation(molecules, target):
            for molecule in molecules:
                molecule["fpga_evaluation"] = copy.deepcopy(fpga_evaluation)
            return {
                "status": fpga_evaluation["status"],
                "accelerated_count": len(molecules),
                "model_profile": fpga_evaluation.get("model_profile"),
                "ranking_eligible": fpga_evaluation.get("ranking_eligible", False),
            }

        with patch("agents.orchestrator.fpga_client.evaluate_molecules", side_effect=attach_evaluation), \
                patch("main.enhanced_manager.broadcast_pipeline_progress", new=AsyncMock()), \
                patch("main.save_history"), patch("main.request_logger.log_agent_execution"):
            return asyncio.run(run_pipeline(self._frontend_profile()))

    def _assert_legacy_pipeline_contract(self, payload):
        self.assertIsInstance(payload["status"], str)
        self.assertIsInstance(payload["pipeline_id"], str)
        self.assertIsInstance(payload["pipeline_status"], str)
        self.assertIsInstance(payload["elapsed_time"], (int, float))
        data = payload["data"]
        self.assertIsInstance(data, dict)
        self.assertIsInstance(data["summary"], dict)
        self.assertIsInstance(data["summary"]["researcher"], str)
        self.assertIsInstance(data["summary"]["target"], str)
        self.assertIsInstance(data["summary"]["total_molecules"], int)

        molecule = data["steps"]["generator"]["result"]["generated_molecules"][0]
        self.assertIsInstance(molecule["id"], str)
        self.assertIsInstance(molecule["smiles"], str)
        self.assertIsInstance(molecule["properties"], dict)

        reviewer = data["steps"]["reviewer"]["result"]
        self.assertIsInstance(reviewer["status"], str)
        self.assertIsInstance(reviewer["total_reviewed"], int)
        self.assertIsInstance(reviewer["scoring_details"], list)
        self.assertIsInstance(reviewer["filtered_molecules"], list)
        detail = reviewer["scoring_details"][0]
        self.assertIsInstance(detail["id"], str)
        self.assertIsInstance(detail["total_score"], (int, float))
        self.assertIsInstance(detail["breakdown"], dict)
        return molecule

    def test_pipeline_post_accepts_and_forwards_the_exact_frontend_profile(self):
        """Removing or renaming a frontend field must fail before Pydantic can ignore it."""
        frontend_payload = {
            "researcher_id": "researcher-demo-001",
            "name": "Demo Researcher",
            "background": "药物化学",
            "experience_years": 2,
            "target": "EGFR",
            "research_goal": "提高选择性",
            "constraints": ["logP < 5"],
            "skills": {"化学信息学": 68},
        }
        captured = {}

        def attach_disabled(molecules, target):
            for molecule in molecules:
                molecule["fpga_evaluation"] = {"status": "disabled", "accelerated": False}
            return {"status": "disabled", "accelerated_count": len(molecules), "ranking_eligible": False}

        def capture_profile(profile):
            captured.update(profile)
            return original_pipeline(profile)

        original_pipeline = orchestrator.run_pipeline
        with patch("main.orchestrator.run_pipeline", side_effect=capture_profile), \
                patch("agents.orchestrator.fpga_client.evaluate_molecules", side_effect=attach_disabled), \
                patch("main.enhanced_manager.broadcast_pipeline_progress", new=AsyncMock()), \
                patch("main.save_history"), patch("main.request_logger.log_agent_execution"):
            response = TestClient(app).post(
                "/api/v1/pipeline", json=frontend_payload, headers={"X-User-Role": "student"}
            )

        self.assertEqual(200, response.status_code)
        self.assertEqual(set(frontend_payload), {
            "researcher_id", "name", "background", "experience_years", "target",
            "research_goal", "constraints", "skills",
        })
        for field, expected in frontend_payload.items():
            self.assertEqual(expected, captured[field])
        molecule = self._assert_legacy_pipeline_contract(response.json())
        self.assertEqual("disabled", molecule["fpga_evaluation"]["status"])

    def test_pipeline_preserves_legacy_fields_when_fpga_is_disabled(self):
        molecule = self._assert_legacy_pipeline_contract(self._run_pipeline({
            "status": "disabled", "accelerated": False,
        }))

        self.assertEqual("disabled", molecule["fpga_evaluation"]["status"])
        self.assertIs(molecule["fpga_evaluation"]["accelerated"], False)

    def test_pipeline_preserves_legacy_fields_when_fpga_is_rank_eligible(self):
        molecule = self._assert_legacy_pipeline_contract(self._run_pipeline({
            "status": "hardware_complete", "accelerated": True,
            "model_profile": "egfr_admet_v1", "ranking_eligible": True,
            "gnn": {"egfr_activity_score": 0.8},
            "tanimoto": {"similarity": 0.7},
            "admet": {
                "lipophilicity_desirability": 0.7, "oral_bioavailability": 0.7,
                "herg_block_risk": 0.2, "bbb_permeability": 0.7,
            },
        }))

        evaluation = molecule["fpga_evaluation"]
        self.assertEqual("egfr_admet_v1", evaluation["model_profile"])
        self.assertIs(evaluation["ranking_eligible"], True)
        self.assertIsInstance(evaluation["gnn"]["egfr_activity_score"], float)

    def test_debate_start_returns_the_id_at_top_level(self):
        session = DebateSession(
            debate_id="debate-1",
            topic="test",
            rounds=[DebateRound(round=1, speaker="Reviewer", content="review", confidence=0.8)],
        )
        with patch("main.V32Services.start_debate", new=AsyncMock(return_value=session)):
            payload = asyncio.run(v32_start_debate(DebateStartRequest(topic="test")))

        self.assertEqual(payload["debate_id"], "debate-1")
        self.assertEqual(payload["first_round"]["content"], "review")

    def test_debate_response_accepts_the_frontend_payload(self):
        request = DebateRespondRequest(response="answer", round=2)
        session = DebateSession(
            debate_id="debate-1",
            topic="test",
            rounds=[DebateRound(round=2, speaker="Generator", content="answer", confidence=0.82)],
        )
        with patch("main.V32Services.debate_respond", new=AsyncMock(return_value=session)):
            payload = asyncio.run(v32_debate_respond("debate-1", request))

        self.assertEqual(payload["next_round"]["content"], "answer")


if __name__ == "__main__":
    unittest.main()
