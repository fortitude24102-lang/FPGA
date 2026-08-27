import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from main import app


class MoleculeToolsFPGAContractTest(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def test_compare_reports_real_fpga_source(self):
        hardware = {
            "similarity": 0.625,
            "raw_q16_16": 40960,
            "method": "Tanimoto (Morgan 1024-bit, FPGA)",
            "accelerated": True,
            "trace_id": "123",
            "compute_time_ms": 1.25,
        }

        with patch("main.fpga_client.compute_tanimoto_smiles", return_value=hardware):
            response = self.client.post(
                "/api/v1/compare", json={"smiles1": "CCO", "smiles2": "CCCO"}
            )

        self.assertEqual(200, response.status_code)
        payload = response.json()
        self.assertEqual("fpga", payload["source"])
        self.assertEqual(hardware, payload["data"])

    def test_compare_falls_back_to_cpu_without_claiming_fpga(self):
        with patch(
            "main.fpga_client.compute_tanimoto_smiles",
            side_effect=OSError("board disconnected"),
        ):
            response = self.client.post(
                "/api/v1/compare", json={"smiles1": "CCO", "smiles2": "CCCO"}
            )

        self.assertEqual(200, response.status_code)
        payload = response.json()
        self.assertEqual("cpu_fallback", payload["source"])
        self.assertFalse(payload["data"]["accelerated"])
        self.assertAlmostEqual(0.556, payload["data"]["similarity"], places=3)

    def test_fingerprint_identifies_cpu_preprocessing(self):
        response = self.client.post("/api/v1/fingerprint?smiles=CCO")

        self.assertEqual(200, response.status_code)
        payload = response.json()
        self.assertEqual("cpu_fallback", payload["source"])
        self.assertFalse(payload["data"]["accelerated"])


if __name__ == "__main__":
    unittest.main()
