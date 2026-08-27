import asyncio
import json
import unittest
from unittest.mock import patch

from main import readiness_check


class ReadyFrontendContractTest(unittest.TestCase):
    def test_ready_exposes_the_service_fields_consumed_by_the_frontend(self):
        response = asyncio.run(readiness_check())
        payload = json.loads(response.body)

        self.assertEqual(payload["api"], "ready")
        self.assertEqual(payload["storage"], "ready")
        self.assertIn(payload["fpga"], ("ready", "offline"))
        self.assertIs(payload["checks"]["api"], True)
        self.assertIs(payload["checks"]["storage"], True)
        self.assertIs(payload["checks"]["fpga"], payload["fpga"] == "ready")
        self.assertEqual(
            payload["services"],
            {
                "api": payload["api"],
                "storage": payload["storage"],
                "fpga": payload["fpga"],
            },
        )

    def test_ready_preserves_service_field_types_when_fpga_is_enabled(self):
        with patch("main._ENABLE_FPGA", True), patch(
            "main.fpga_client.get_health", return_value={"online": True, "fault": False}
        ):
            response = asyncio.run(readiness_check())
        payload = json.loads(response.body)

        self.assertIsInstance(payload["ready"], bool)
        self.assertIsInstance(payload["status"], str)
        self.assertIsInstance(payload["api"], str)
        self.assertIsInstance(payload["storage"], str)
        self.assertIsInstance(payload["fpga"], str)
        self.assertIsInstance(payload["services"], dict)
        self.assertIsInstance(payload["checks"], dict)
        self.assertIs(payload["checks"]["fpga"], True)
        self.assertEqual("ready", payload["fpga"])


if __name__ == "__main__":
    unittest.main()
