#!/usr/bin/env python3
"""Behavior tests for the DMA implementation report gate."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

try:
    from .check_dma_reports import REQUIRED_REPORTS, gate_report_directory
except ImportError:
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
    "clock_125_present": "1",
    "clock_100_wns": "0.100",
    "clock_100_tns": "0.000",
    "clock_100_whs": "0.050",
    "clock_125_wns": "0.020",
    "clock_125_tns": "0.000",
    "clock_125_whs": "0.010",
    "clock_33_present": "1",
    "clock_core_100_present": "1",
    "clock_core_100_wns": "0.015",
    "clock_core_100_tns": "0.000",
    "clock_core_100_whs": "0.008",
    "clock_core_150_experimental": "1",
    "global_wns": "0.020",
    "global_tns": "0.000",
    "global_whs": "0.010",
    "build_mode": "release",
    "runtime_profiles_mhz": "50,100,150",
    "ila_present": "0",
    "ila_queue_occupancy_probe": "0",
    "ila_engine_start_probe": "0",
    "ila_engine_busy_probe": "0",
    "ila_engine_done_probe": "0",
    "ila_active_sequence_probe": "0",
    "ila_clock_profile_probe": "0",
    "result_pool_bram_cells": "16",
    "weight_bank_bram_cells": "32",
    "rtl_ip_sources_match": "1",
    "bitstream_exists": "1",
    "xsa_exists": "1",
}


class DmaReportGateTests(unittest.TestCase):
    def test_vivado_2019_2_power_optimization_is_disabled(self) -> None:
        script = (Path(__file__).parent / "rebuild_dma_batch.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "STEPS.OPT_DESIGN.ARGS.DIRECTIVE NoBramPowerOpt", script
        )
        self.assertIn("STEPS.POWER_OPT_DESIGN.IS_ENABLED false", script)

    def test_release_place_disables_psip_for_proven_slice_packing(self) -> None:
        script = (Path(__file__).parent / "rebuild_dma_batch.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "-name {STEPS.PLACE_DESIGN.ARGS.MORE OPTIONS} -value {-no_psip}",
            script,
        )

    def test_build_measures_weight_banks_in_block_ram(self) -> None:
        script = (Path(__file__).parent / "rebuild_dma_batch.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("weight_bank_bram_cells", script)
        self.assertIn("REF_NAME =~ RAMB*", script)

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
        self.assert_rejected("clock_125_wns", "-0.001", "clock_125_wns")

    def test_rejects_negative_hold_slack(self) -> None:
        self.assert_rejected("clock_100_whs", "-0.002", "clock_100_whs")

    def test_rejects_zero_slack(self) -> None:
        self.assert_rejected("clock_125_whs", "0.000", "clock_125_whs")

    def test_rejects_drc_errors(self) -> None:
        self.assert_rejected("drc_errors", "1", "drc_errors")

    def test_rejects_dsp_over_project_limit(self) -> None:
        self.assert_rejected("dsp_used", "81", "project limit 80")

    def test_rejects_missing_125_mhz_clock(self) -> None:
        self.assert_rejected("clock_125_present", "0", "clock_125_present")

    def test_rejects_missing_33_mhz_clock(self) -> None:
        self.assert_rejected("clock_33_present", "0", "clock_33_present")

    def test_rejects_missing_100_mhz_core_clock(self) -> None:
        self.assert_rejected(
            "clock_core_100_present", "0", "clock_core_100_present"
        )

    def test_rejects_nonpositive_100_mhz_core_setup(self) -> None:
        self.assert_rejected("clock_core_100_wns", "0", "clock_core_100_wns")

    def test_rejects_nonpositive_100_mhz_core_hold(self) -> None:
        self.assert_rejected("clock_core_100_whs", "-0.001", "clock_core_100_whs")

    def test_accepts_experimental_150_mhz_without_timing_claim(self) -> None:
        self.assertEqual(gate_report_directory(self.make_reports()), [])

    def test_requires_150_mhz_experimental_marker(self) -> None:
        self.assert_rejected(
            "clock_core_150_experimental", "0", "clock_core_150_experimental"
        )

    def test_clock_wizard_defaults_core_to_100_mhz(self) -> None:
        create = (Path(__file__).parent / "add_dma_batch_system.tcl").read_text(
            encoding="utf-8"
        )
        check = (Path(__file__).parent / "check_dma_batch_bd.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn("CLKOUT1_REQUESTED_OUT_FREQ {100.000}", create)
        self.assertIn("CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 100.000", check)

    def test_rejects_wrong_runtime_profiles(self) -> None:
        self.assert_rejected(
            "runtime_profiles_mhz", "50,100", "runtime_profiles_mhz"
        )

    def test_rejects_release_ila(self) -> None:
        self.assert_rejected("ila_present", "1", "release build contains ILA")

    def test_accepts_debug_ila_with_required_probes(self) -> None:
        overrides = {
            "build_mode": "debug",
            "ila_present": "1",
            "ila_queue_occupancy_probe": "1",
            "ila_engine_start_probe": "1",
            "ila_engine_busy_probe": "1",
            "ila_engine_done_probe": "1",
            "ila_active_sequence_probe": "1",
            "ila_clock_profile_probe": "1",
        }
        self.assertEqual(gate_report_directory(self.make_reports(overrides)), [])

    def test_rejects_debug_missing_required_probe(self) -> None:
        failures = gate_report_directory(
            self.make_reports({
                "build_mode": "debug",
                "ila_present": "1",
                "ila_active_sequence_probe": "0",
            })
        )
        self.assertTrue(
            any("ila_active_sequence_probe" in item for item in failures), failures
        )

    def test_rejects_unknown_build_mode(self) -> None:
        self.assert_rejected("build_mode", "profile", "build_mode")

    def test_rejects_missing_result_pool_bram(self) -> None:
        self.assert_rejected("result_pool_bram_cells", "0", "result_pool_bram_cells")

    def test_rejects_weight_banks_left_in_distributed_ram(self) -> None:
        self.assert_rejected(
            "weight_bank_bram_cells", "0", "weight_bank_bram_cells"
        )

    def test_rejects_stale_packaged_rtl(self) -> None:
        self.assert_rejected("rtl_ip_sources_match", "0", "rtl_ip_sources_match")

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
