#!/usr/bin/env python3
"""Compile and run every self-checking RTL regression with Icarus Verilog."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
SIM = ROOT / "sim"
PROTOCOL_TEST = SIM / "test_dma_protocol_codegen.py"
PROTOCOL_GENERATOR = ROOT / "tools" / "generate_dma_protocol.py"

TESTS = {
    "dma_queue": (
        "tb_dma_task_queue",
        [RTL / "dma_task_queue.v", SIM / "tb_dma_task_queue.sv"],
    ),
    "tanimoto_stream_batch": (
        "tb_tanimoto_stream_batch",
        [
            RTL / "tanimoto_accelerator.v",
            RTL / "tanimoto_stream_batch.v",
            SIM / "tb_tanimoto_stream_batch.sv",
        ],
    ),
    "dma_formatter": (
        "tb_dma_result_formatter",
        [RTL / "dma_result_formatter.v", SIM / "tb_dma_result_formatter.sv"],
    ),
    "dma_formatter_errors": (
        "tb_dma_result_formatter_errors",
        [RTL / "dma_result_formatter.v", SIM / "tb_dma_result_formatter_errors.sv"],
    ),
    "dma_formatter_keep": (
        "tb_dma_result_formatter_keep",
        [RTL / "dma_result_formatter.v", SIM / "tb_dma_result_formatter_keep.sv"],
    ),
    "dma_frontend": (
        "tb_dma_task_queue_frontend",
        [RTL / "dma_task_queue_frontend.v", SIM / "tb_dma_task_queue_frontend.sv"],
    ),
    "dma_frontend_errors": (
        "tb_dma_task_queue_frontend_errors",
        [
            RTL / "dma_task_queue_frontend.v",
            SIM / "tb_dma_task_queue_frontend_errors.sv",
        ],
    ),
    "dma_frontend_tasks": (
        "tb_dma_task_queue_frontend_tasks",
        [
            RTL / "dma_task_queue_frontend.v",
            SIM / "tb_dma_task_queue_frontend_tasks.sv",
        ],
    ),
    "tanimoto": (
        "tb_tanimoto",
        [RTL / "tanimoto_accelerator.v", SIM / "tb_tanimoto.sv"],
    ),
    "gnn": (
        "tb_gnn",
        [RTL / "gnn_message_passing.v", SIM / "tb_gnn.sv"],
    ),
    "gnn_latency": (
        "tb_gnn_latency",
        [RTL / "gnn_message_passing.v", SIM / "tb_gnn_latency.sv"],
    ),
    "fc_network": (
        "tb_fc_network",
        [RTL / "fc_network.v", SIM / "tb_fc_network.sv"],
    ),
    "admet": (
        "tb_admet",
        [
            RTL / "fc_network.v",
            RTL / "admet_predictor.v",
            SIM / "tb_admet.sv",
        ],
    ),
    "top": (
        "tb_top",
        [
            RTL / "tanimoto_accelerator.v",
            RTL / "gnn_message_passing.v",
            RTL / "fc_network.v",
            RTL / "admet_predictor.v",
            RTL / "tanimoto_stream_batch.v",
            RTL / "dma_task_queue_frontend.v",
            RTL / "dma_task_queue.v",
            RTL / "dma_result_formatter.v",
            RTL / "dma_accelerator_backend.v",
            RTL / "generator_accelerator_top.v",
            SIM / "tb_top.sv",
        ],
    ),
    "top_dma": (
        "tb_top_dma",
        [
            RTL / "tanimoto_accelerator.v",
            RTL / "gnn_message_passing.v",
            RTL / "fc_network.v",
            RTL / "admet_predictor.v",
            RTL / "tanimoto_stream_batch.v",
            RTL / "dma_task_queue_frontend.v",
            RTL / "dma_task_queue.v",
            RTL / "dma_result_formatter.v",
            RTL / "dma_accelerator_backend.v",
            RTL / "generator_accelerator_top.v",
            SIM / "tb_top_dma.sv",
        ],
    ),
    "top_dma_tasks": (
        "tb_top_dma_tasks",
        [
            RTL / "tanimoto_accelerator.v",
            RTL / "gnn_message_passing.v",
            RTL / "fc_network.v",
            RTL / "admet_predictor.v",
            RTL / "tanimoto_stream_batch.v",
            RTL / "dma_task_queue_frontend.v",
            RTL / "dma_task_queue.v",
            RTL / "dma_result_formatter.v",
            RTL / "dma_accelerator_backend.v",
            RTL / "generator_accelerator_top.v",
            SIM / "tb_top_dma_tasks.sv",
        ],
    ),
    "top_dma_arbitration": (
        "tb_top_dma_arbitration",
        [
            RTL / "tanimoto_accelerator.v",
            RTL / "gnn_message_passing.v",
            RTL / "fc_network.v",
            RTL / "admet_predictor.v",
            RTL / "tanimoto_stream_batch.v",
            RTL / "dma_task_queue_frontend.v",
            RTL / "dma_task_queue.v",
            RTL / "dma_result_formatter.v",
            RTL / "dma_accelerator_backend.v",
            RTL / "generator_accelerator_top.v",
            SIM / "tb_top_dma_arbitration.sv",
        ],
    ),
}


def find_tool(name: str, fallback: str) -> str:
    return shutil.which(name) or (fallback if Path(fallback).exists() else "")


def run_command(command: list[str], log_path: Path) -> int:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    log_path.write_text(completed.stdout, encoding="utf-8")
    print(completed.stdout, end="")
    return completed.returncode


def run_protocol_checks(build_dir: Path, include_unit_tests: bool) -> bool:
    if include_unit_tests:
        print("\n===== protocol: unit tests =====")
        if run_command(
            [sys.executable, str(PROTOCOL_TEST)],
            build_dir / "protocol_unit.log",
        ) != 0:
            return False

    print("\n===== protocol: generated-file check =====")
    if run_command(
        [sys.executable, str(PROTOCOL_GENERATOR), "--check"],
        build_dir / "protocol_check.log",
    ) != 0:
        return False
    print("Protocol generated-file check passed")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build-dir", type=Path, default=SIM / "build", help="output directory"
    )
    parser.add_argument(
        "--test",
        choices=["all", "protocol", *TESTS],
        default="all",
        help="run one regression or all",
    )
    args = parser.parse_args()

    args.build_dir.mkdir(parents=True, exist_ok=True)
    if args.test == "protocol":
        return 0 if run_protocol_checks(args.build_dir, include_unit_tests=False) else 1

    iverilog = find_tool("iverilog", r"C:\iverilog\bin\iverilog.exe")
    vvp = find_tool("vvp", r"C:\iverilog\bin\vvp.exe")
    if not iverilog or not vvp:
        print("error: Icarus Verilog (iverilog and vvp) was not found", file=sys.stderr)
        return 2

    selected = TESTS if args.test == "all" else {args.test: TESTS[args.test]}
    failures: list[str] = []

    if args.test == "all" and not run_protocol_checks(
        args.build_dir, include_unit_tests=True
    ):
        failures.append("protocol")

    for name, (top, sources) in selected.items():
        print(f"\n===== {name}: compile =====")
        output = args.build_dir / f"{name}.vvp"
        compile_command = [
            iverilog,
            "-g2012",
            "-Wall",
            "-I",
            str(RTL),
            "-s",
            top,
            "-o",
            str(output),
            *(str(source) for source in sources),
        ]
        if run_command(
            compile_command, args.build_dir / f"{name}_compile.log"
        ) != 0:
            failures.append(f"{name} (compile)")
            continue

        print(f"===== {name}: run =====")
        if run_command(
            [vvp, str(output)], args.build_dir / f"{name}_run.log"
        ) != 0:
            failures.append(f"{name} (run)")

    print("\n===== regression summary =====")
    if failures:
        print("FAILED: " + ", ".join(failures))
        return 1
    protocol_count = 1 if args.test == "all" else 0
    print(f"PASSED: {len(selected)} RTL testbenches and {protocol_count} protocol check")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
