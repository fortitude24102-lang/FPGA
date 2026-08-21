#!/usr/bin/env python3
"""Gate a DMA-batch Vivado candidate using machine-readable build evidence."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


REQUIRED_REPORTS = (
    "gate_metrics.txt",
    "timing_summary.rpt",
    "utilization.rpt",
    "utilization_hierarchical.rpt",
    "route_status.rpt",
    "drc.rpt",
    "methodology_drc.rpt",
    "clocks.rpt",
    "synth_messages.txt",
)

REQUIRED_KEYS = (
    "route_complete",
    "unrouted_nets",
    "drc_errors",
    "methodology_errors",
    "dsp_used",
    "dsp_available",
    "lut_used",
    "lut_available",
    "ff_used",
    "ff_available",
    "bram_used",
    "bram_available",
    "clock_100_present",
    "clock_125_present",
    "clock_100_wns",
    "clock_100_whs",
    "clock_125_wns",
    "clock_125_whs",
    "global_wns",
    "global_whs",
    "bitstream_exists",
    "xsa_exists",
)

FORBIDDEN_SYNTH_PATTERNS = {
    "unsupported inferred memory": re.compile(
        r"unable to infer a block/distributed RAM|failed synthesizing module",
        re.IGNORECASE,
    ),
    "multi-driven net": re.compile(
        r"multi[- ]driven|multiple driver|multiple drivers", re.IGNORECASE
    ),
    "queue latch warning": re.compile(
        r"latch.*(?:dma_task_queue|dma_result_formatter|dma_accelerator_backend)",
        re.IGNORECASE,
    ),
}

UTILIZATION_ROWS = {
    "lut": re.compile(r"^\|\s*Slice LUTs\s*\|\s*([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)\s*\|", re.MULTILINE),
    "ff": re.compile(r"^\|\s*Slice Registers\s*\|\s*([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)\s*\|", re.MULTILINE),
    "bram": re.compile(r"^\|\s*Block RAM Tile\s*\|\s*([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)\s*\|", re.MULTILINE),
    "dsp": re.compile(r"^\|\s*DSPs\s*\|\s*([0-9.]+)\s*\|\s*[0-9.]+\s*\|\s*([0-9.]+)\s*\|", re.MULTILINE),
}


def load_metrics(path: Path) -> dict[str, str]:
    metrics: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path.name}:{line_number}: expected key=value")
        key, value = (field.strip() for field in line.split("=", 1))
        if not key or not value:
            raise ValueError(f"{path.name}:{line_number}: empty key or value")
        if key in metrics:
            raise ValueError(f"{path.name}:{line_number}: duplicate key {key}")
        metrics[key] = value
    return metrics


def gate_report_directory(report_dir: Path) -> list[str]:
    failures: list[str] = []
    for name in REQUIRED_REPORTS:
        path = report_dir / name
        if not path.is_file() or path.stat().st_size == 0:
            failures.append(f"missing or empty report: {name}")
    if failures:
        return failures

    try:
        metrics = load_metrics(report_dir / "gate_metrics.txt")
    except (OSError, UnicodeError, ValueError) as error:
        return [str(error)]

    for key in REQUIRED_KEYS:
        if key not in metrics:
            failures.append(f"missing metric: {key}")
    if failures:
        return failures

    def number(key: str) -> float:
        try:
            return float(metrics[key])
        except ValueError:
            failures.append(f"metric {key} is not numeric: {metrics[key]}")
            return float("nan")

    for key in ("route_complete", "clock_100_present", "clock_125_present",
                "bitstream_exists", "xsa_exists"):
        if number(key) != 1.0:
            failures.append(f"{key} must equal 1")

    for key in ("unrouted_nets", "drc_errors", "methodology_errors"):
        if number(key) != 0.0:
            failures.append(f"{key} must equal 0 (got {metrics[key]})")

    for key in ("clock_100_wns", "clock_100_whs",
                "clock_125_wns", "clock_125_whs",
                "global_wns", "global_whs"):
        if number(key) <= 0.0:
            failures.append(f"{key} is not positive ({metrics[key]} ns)")

    dsp_used = number("dsp_used")
    if dsp_used > 80.0:
        failures.append(f"dsp_used exceeds project limit 80 (got {metrics['dsp_used']})")

    for resource in ("dsp", "lut", "ff", "bram"):
        used = number(f"{resource}_used")
        available = number(f"{resource}_available")
        if used > available:
            failures.append(
                f"{resource}_used exceeds device capacity ({used:g}>{available:g})"
            )

    utilization_text = (report_dir / "utilization.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    for resource, pattern in UTILIZATION_ROWS.items():
        match = pattern.search(utilization_text)
        if match is None:
            failures.append(f"utilization.rpt missing {resource} summary row")
            continue
        report_used, report_available = (float(value) for value in match.groups())
        metric_used = number(f"{resource}_used")
        metric_available = number(f"{resource}_available")
        if abs(report_used - metric_used) > 0.001:
            failures.append(
                f"{resource}_used metric/report mismatch "
                f"({metric_used:g}!={report_used:g})"
            )
        if abs(report_available - metric_available) > 0.001:
            failures.append(
                f"{resource}_available metric/report mismatch "
                f"({metric_available:g}!={report_available:g})"
            )

    try:
        synth_text = (report_dir / "synth_messages.txt").read_text(
            encoding="utf-8", errors="replace"
        )
    except OSError as error:
        failures.append(str(error))
    else:
        diagnostic_text = "\n".join(
            line for line in synth_text.splitlines()
            if re.match(r"^\s*(?:ERROR|CRITICAL WARNING|WARNING):", line,
                        re.IGNORECASE)
        )
        for label, pattern in FORBIDDEN_SYNTH_PATTERNS.items():
            if pattern.search(diagnostic_text):
                failures.append(f"synthesis log contains {label}")

    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report_dir", type=Path)
    args = parser.parse_args()
    failures = gate_report_directory(args.report_dir)
    if failures:
        for failure in failures:
            print(f"GATE_FAIL: {failure}")
        print(f"DMA_REPORT_GATE_FAILED count={len(failures)}")
        return 1
    print("DMA_REPORT_GATE_PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
