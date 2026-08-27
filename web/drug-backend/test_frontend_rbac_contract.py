import unittest

from main import RBACMiddleware


class FrontendRBACContractTest(unittest.TestCase):
    def test_default_frontend_role_can_use_the_recommendation_workflow(self):
        paths = [
            "/api/v1/agents/status",
            "/api/v1/pipeline",
            "/api/v1/feedback",
            "/api/v1/fingerprint",
            "/api/v1/compare",
            "/api/v1/molecule/properties",
            "/api/debate/start",
            "/api/debate/demo/rounds",
            "/api/debate/demo/verdict",
            "/api/resources/demo/provenance",
            "/api/hallucination/check",
            "/api/hallucination/stats",
            "/api/batch-test/run",
            "/api/batch-test/results",
        ]

        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(RBACMiddleware.check_permission(path, "student"))


if __name__ == "__main__":
    unittest.main()
