#!/usr/bin/env python3
"""Behavior tests for the DMA implementation report gate."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from check_dma_reports import REQUIRED_REPORTS, gate_report_directory


GOOD_METRICS = {
    "route_complete": "1",
    "unrouted_nets": "0",
    "drc_errors": "0",
    "methodology_errors": "0",
    "dsp_used": "78",
    "dsp_available": "160",
    "lut_used": "30000",
    "lut_available": "46200",
    "ff_used": "20000",
    "ff_available": "92400",
    "bram_used": "20",
    "bram_available": "95",
    "clock_100_present": "1",
    "clock_150_present": "1",
    "clock_100_wns": "0.100",
    "clock_100_whs": "0.050",
    "clock_150_wns": "0.020",
    "clock_150_whs": "0.010",
    "global_wns": "0.020",
    "global_whs": "0.010",
    "bitstream_exists": "1",
    "xsa_exists": "1",
}


class DmaReportGateTests(unittest.TestCase):
    def make_reports(self, overrides: dict[str, str] | None = None) -> Path:
        temporary = Path(self.addCleanupTemporaryDirectory())
        metrics = dict(GOOD_METRICS)
        metrics.update(overrides or {})
        for name in REQUIRED_REPORTS:
            path = temporary / name
            if name == "gate_metrics.txt":
                path.write_text(
                    "".join(f"{key}={value}\n" for key, value in metrics.items()),
                    encoding="utf-8",
                )
            elif name == "utilization.rpt":
                path.write_text(
                    f"| Slice LUTs | {metrics['lut_used']} | 0 | {metrics['lut_available']} | 0 |\n"
                    f"| Slice Registers | {metrics['ff_used']} | 0 | {metrics['ff_available']} | 0 |\n"
                    f"| Block RAM Tile | {metrics['bram_used']} | 0 | {metrics['bram_available']} | 0 |\n"
                    f"| DSPs | {metrics['dsp_used']} | 0 | {metrics['dsp_available']} | 0 |\n",
                    encoding="utf-8",
                )
            else:
                path.write_text("synthetic passing report\n", encoding="utf-8")
        return temporary

    def addCleanupTemporaryDirectory(self) -> str:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return temporary.name

    def assert_rejected(self, key: str, value: str, expected: str) -> None:
        failures = gate_report_directory(self.make_reports({key: value}))
        self.assertTrue(any(expected in failure for failure in failures), failures)

    def test_accepts_complete_passing_candidate(self) -> None:
        self.assertEqual(gate_report_directory(self.make_reports()), [])

    def test_rejects_negative_setup_slack(self) -> None:
        self.assert_rejected("clock_150_wns", "-0.001", "clock_150_wns")

    def test_rejects_negative_hold_slack(self) -> None:
        self.assert_rejected("clock_100_whs", "-0.002", "clock_100_whs")

    def test_rejects_drc_errors(self) -> None:
        self.assert_rejected("drc_errors", "1", "drc_errors")

    def test_rejects_dsp_over_project_limit(self) -> None:
        self.assert_rejected("dsp_used", "81", "project limit 80")

    def test_rejects_missing_150_mhz_clock(self) -> None:
        self.assert_rejected("clock_150_present", "0", "clock_150_present")

    def test_rejects_unrouted_design(self) -> None:
        self.assert_rejected("route_complete", "0", "route_complete")

    def test_ignores_zero_multidriven_summary_row(self) -> None:
        reports = self.make_reports()
        (reports / "synth_messages.txt").write_text(
            "| multi_driven_nets | 0 | 0 | Passed | Multi driven nets |\n",
            encoding="utf-8",
        )
        self.assertEqual(gate_report_directory(reports), [])

    def test_rejects_real_multidriven_warning(self) -> None:
        reports = self.make_reports()
        (reports / "synth_messages.txt").write_text(
            "WARNING: multiple drivers found on queue_status\n",
            encoding="utf-8",
        )
        failures = gate_report_directory(reports)
        self.assertTrue(any("multi-driven net" in item for item in failures), failures)

    def test_rejects_utilization_metric_mismatch(self) -> None:
        reports = self.make_reports()
        text = (reports / "utilization.rpt").read_text(encoding="utf-8")
        (reports / "utilization.rpt").write_text(
            text.replace("| Slice LUTs | 30000 |", "| Slice LUTs | 30001 |"),
            encoding="utf-8",
        )
        failures = gate_report_directory(reports)
        self.assertTrue(any("lut_used metric/report mismatch" in item for item in failures), failures)


if __name__ == "__main__":
    unittest.main(verbosity=2)
