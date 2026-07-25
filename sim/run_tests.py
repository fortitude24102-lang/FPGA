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

TESTS = {
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
            RTL / "generator_accelerator_top.v",
            SIM / "tb_top.sv",
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build-dir", type=Path, default=SIM / "build", help="output directory"
    )
    parser.add_argument(
        "--test",
        choices=["all", *TESTS],
        default="all",
        help="run one regression or all",
    )
    args = parser.parse_args()

    iverilog = find_tool("iverilog", r"C:\iverilog\bin\iverilog.exe")
    vvp = find_tool("vvp", r"C:\iverilog\bin\vvp.exe")
    if not iverilog or not vvp:
        print("error: Icarus Verilog (iverilog and vvp) was not found", file=sys.stderr)
        return 2

    args.build_dir.mkdir(parents=True, exist_ok=True)
    selected = TESTS if args.test == "all" else {args.test: TESTS[args.test]}
    failures: list[str] = []

    for name, (top, sources) in selected.items():
        print(f"\n===== {name}: compile =====")
        output = args.build_dir / f"{name}.vvp"
        compile_command = [
            iverilog,
            "-g2012",
            "-Wall",
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
    print(f"PASSED: {len(selected)} testbenches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
