import asyncio
import unittest

from main import (
    HallucinationCheckRequest,
    v32_check_hallucination,
    v32_get_hallucination_stats,
)


class HallucinationFrontendContractTest(unittest.TestCase):
    def test_accepts_frontend_smiles_payload_and_returns_display_fields(self):
        request = HallucinationCheckRequest(smiles="CCO", source="frontend")
        payload = asyncio.run(v32_check_hallucination(request))

        self.assertEqual(set(payload), {"rate", "level", "types", "rdkit_basis"})
        self.assertEqual(payload["level"], "trusted")

    def test_stats_are_returned_in_the_frontend_shape(self):
        payload = asyncio.run(v32_get_hallucination_stats())

        self.assertEqual(
            set(payload),
            {"hallucination_rate", "success_rate", "coverage"},
        )


if __name__ == "__main__":
    unittest.main()
