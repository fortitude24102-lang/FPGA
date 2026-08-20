import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATCHER = ROOT / "software" / "patch_lwip_yt8531.py"
VITIS_SOURCE = Path(
    r"D:\visit\Vitis\2019.2\data\embeddedsw\ThirdParty\sw_services"
    r"\lwip202_v1_1\src\contrib\ports\xilinx\netif\xemacpsif_physpeed.c"
)


class Yt8531PatchTests(unittest.TestCase):
    def run_patcher(self, source: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(PATCHER), str(source)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_patch_is_idempotent_and_preserves_vendor_drivers(self) -> None:
        self.assertTrue(VITIS_SOURCE.exists(), VITIS_SOURCE)
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "xemacpsif_physpeed.c"
            source.write_bytes(VITIS_SOURCE.read_bytes())

            first = self.run_patcher(source)
            self.assertEqual(first.returncode, 0, first.stderr)
            once = source.read_bytes()

            second = self.run_patcher(source)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(once, source.read_bytes())

            patched = once.decode("utf-8")
            self.assertIn("MOLRECOMMENDER_GENERIC_PHY_BEGIN", patched)
            self.assertIn("get_Generic_phy_speed", patched)
            self.assertIn("get_TI_phy_speed", patched)
            self.assertIn("get_Realtek_phy_speed", patched)
            self.assertIn("get_Marvell_phy_speed", patched)
            self.assertIn(
                "RetStatus = get_Generic_phy_speed(xemacpsp, phy_addr);",
                patched,
            )

    def test_rejects_an_unrecognized_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "unexpected.c"
            source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
            result = self.run_patcher(source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unsupported lwIP source", result.stderr)


if __name__ == "__main__":
    unittest.main()
