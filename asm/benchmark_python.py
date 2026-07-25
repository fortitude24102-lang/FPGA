#!/usr/bin/env python3
"""Benchmark software references and calculate measured FPGA speedups.

The script has no third-party dependencies.  It always reports Python
baselines.  When --fpga-results points to measured hardware timings, it also
computes speedups and checks the targets from FGPA(1).docx.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import time
from pathlib import Path
from typing import Callable, Sequence


TARGET_SPEEDUPS = {
    "tanimoto": 50.0,
    "gnn": 10.0,
    "admet": 20.0,
    "end_to_end": 30.0,
}


def population_count(value: int) -> int:
    if hasattr(value, "bit_count"):
        return value.bit_count()
    return bin(value).count("1")


def tanimoto(query: int, database: int) -> float:
    union = population_count(query | database)
    if union == 0:
        return 0.0
    return population_count(query & database) / union


def gnn_layer(
    features: Sequence[Sequence[float]],
    adjacency: Sequence[Sequence[int]],
    weights: Sequence[Sequence[float]],
) -> list[list[float]]:
    node_count = len(features)
    feature_dim = len(features[0])
    hidden_dim = len(weights[0])
    output = [[0.0] * hidden_dim for _ in range(node_count)]
    for node in range(node_count):
        aggregate = [0.0] * feature_dim
        for neighbor in range(node_count):
            if adjacency[node][neighbor]:
                neighbor_features = features[neighbor]
                for feature in range(feature_dim):
                    aggregate[feature] += neighbor_features[feature]
        for hidden in range(hidden_dim):
            accumulator = 0.0
            for feature in range(feature_dim):
                accumulator += aggregate[feature] * weights[feature][hidden]
            output[node][hidden] = max(0.0, accumulator)
    return output


def sigmoid(value: float) -> float:
    if value >= 0:
        exp_value = math.exp(-value)
        return 1.0 / (1.0 + exp_value)
    exp_value = math.exp(value)
    return exp_value / (1.0 + exp_value)


def fc_predict(
    descriptors: Sequence[float],
    hidden_weights: Sequence[Sequence[float]],
    hidden_biases: Sequence[float],
    output_weights: Sequence[float],
    output_bias: float,
) -> float:
    hidden_values = []
    for hidden, bias in enumerate(hidden_biases):
        accumulator = bias
        for input_index, descriptor in enumerate(descriptors):
            accumulator += descriptor * hidden_weights[input_index][hidden]
        hidden_values.append(max(0.0, accumulator))
    output = output_bias
    for hidden, hidden_value in enumerate(hidden_values):
        output += hidden_value * output_weights[hidden]
    return sigmoid(output)


def benchmark(operation: Callable[[], object], repeats: int) -> dict[str, float]:
    samples_ms: list[float] = []
    operation()  # warm-up
    for _ in range(repeats):
        start_ns = time.perf_counter_ns()
        operation()
        elapsed_ns = time.perf_counter_ns() - start_ns
        samples_ms.append(elapsed_ns / 1_000_000.0)
    return {
        "mean_ms": statistics.fmean(samples_ms),
        "median_ms": statistics.median(samples_ms),
        "minimum_ms": min(samples_ms),
        "maximum_ms": max(samples_ms),
        "repeats": repeats,
    }


def build_workload(seed: int, molecule_count: int) -> dict[str, object]:
    rng = random.Random(seed)
    query = rng.getrandbits(1024)
    fingerprints = [rng.getrandbits(1024) for _ in range(molecule_count)]

    node_count = 50
    feature_dim = 64
    hidden_dim = 128
    features = [
        [rng.uniform(-1.0, 1.0) for _ in range(feature_dim)]
        for _ in range(node_count)
    ]
    adjacency = [[0] * node_count for _ in range(node_count)]
    for node in range(node_count):
        adjacency[node][node] = 1
        if node + 1 < node_count:
            adjacency[node][node + 1] = 1
            adjacency[node + 1][node] = 1
    gnn_weights = [
        [rng.uniform(-0.25, 0.25) for _ in range(hidden_dim)]
        for _ in range(feature_dim)
    ]

    descriptors = [
        [rng.uniform(-1.0, 1.0) for _ in range(20)]
        for _ in range(molecule_count)
    ]
    admet_models = []
    for _ in range(4):
        admet_models.append(
            {
                "hidden_weights": [
                    [rng.uniform(-0.5, 0.5) for _ in range(10)]
                    for _ in range(20)
                ],
                "hidden_biases": [rng.uniform(-0.25, 0.25) for _ in range(10)],
                "output_weights": [rng.uniform(-0.5, 0.5) for _ in range(10)],
                "output_bias": rng.uniform(-0.25, 0.25),
            }
        )
    return {
        "query": query,
        "fingerprints": fingerprints,
        "features": features,
        "adjacency": adjacency,
        "gnn_weights": gnn_weights,
        "descriptors": descriptors,
        "admet_models": admet_models,
    }


def run_benchmarks(args: argparse.Namespace) -> dict[str, object]:
    workload = build_workload(args.seed, args.molecules)
    query = workload["query"]
    fingerprints = workload["fingerprints"]
    features = workload["features"]
    adjacency = workload["adjacency"]
    gnn_weights = workload["gnn_weights"]
    descriptors = workload["descriptors"]
    admet_models = workload["admet_models"]

    def tanimoto_batch() -> list[float]:
        return [tanimoto(query, fingerprint) for fingerprint in fingerprints]

    def gnn_single() -> list[list[float]]:
        return gnn_layer(features, adjacency, gnn_weights)

    def admet_batch() -> list[list[float]]:
        results: list[list[float]] = []
        for descriptor_row in descriptors:
            results.append(
                [
                    fc_predict(
                        descriptor_row,
                        model["hidden_weights"],
                        model["hidden_biases"],
                        model["output_weights"],
                        model["output_bias"],
                    )
                    for model in admet_models
                ]
            )
        return results

    tanimoto_result = benchmark(tanimoto_batch, args.repeats)
    gnn_result = benchmark(gnn_single, args.repeats)
    admet_result = benchmark(admet_batch, args.repeats)

    # One end-to-end unit uses one fingerprint comparison, one graph and one
    # four-model ADMET prediction.  Normalize batch timings per molecule.
    per_molecule_tanimoto = tanimoto_result["mean_ms"] / args.molecules
    per_molecule_admet = admet_result["mean_ms"] / args.molecules
    end_to_end_mean = (
        per_molecule_tanimoto + gnn_result["mean_ms"] + per_molecule_admet
    )

    report: dict[str, object] = {
        "environment": {
            "python": __import__("sys").version,
            "timer": "time.perf_counter_ns",
            "seed": args.seed,
            "molecules": args.molecules,
        },
        "python": {
            "tanimoto_batch": tanimoto_result,
            "tanimoto_per_molecule_ms": per_molecule_tanimoto,
            "gnn_single_graph": gnn_result,
            "admet_batch": admet_result,
            "admet_per_molecule_ms": per_molecule_admet,
            "end_to_end_per_molecule_ms": end_to_end_mean,
        },
        "targets": TARGET_SPEEDUPS,
    }

    if args.fpga_results:
        hardware = json.loads(args.fpga_results.read_text(encoding="utf-8"))
        required = {
            "tanimoto_ms",
            "gnn_ms",
            "admet_ms",
            "end_to_end_ms",
        }
        missing = required.difference(hardware)
        if missing:
            raise ValueError(
                "FPGA result JSON is missing: " + ", ".join(sorted(missing))
            )
        speedups = {
            "tanimoto": per_molecule_tanimoto / float(hardware["tanimoto_ms"]),
            "gnn": gnn_result["mean_ms"] / float(hardware["gnn_ms"]),
            "admet": per_molecule_admet / float(hardware["admet_ms"]),
            "end_to_end": end_to_end_mean
            / float(hardware["end_to_end_ms"]),
        }
        report["fpga"] = hardware
        report["speedups"] = speedups
        report["target_results"] = {
            name: {
                "target": target,
                "measured": speedups[name],
                "pass": speedups[name] > target,
            }
            for name, target in TARGET_SPEEDUPS.items()
        }
    return report


def markdown_report(report: dict[str, object]) -> str:
    python_results = report["python"]
    lines = [
        "# FPGA accelerator benchmark",
        "",
        "## Python baseline",
        "",
        "| Workload | Mean time |",
        "|---|---:|",
        (
            "| Tanimoto, per molecule | "
            f"{python_results['tanimoto_per_molecule_ms']:.6f} ms |"
        ),
        (
            "| GNN, one 50-node graph | "
            f"{python_results['gnn_single_graph']['mean_ms']:.6f} ms |"
        ),
        (
            "| ADMET four-model prediction, per molecule | "
            f"{python_results['admet_per_molecule_ms']:.6f} ms |"
        ),
        (
            "| End-to-end, per molecule | "
            f"{python_results['end_to_end_per_molecule_ms']:.6f} ms |"
        ),
        "",
    ]
    if "speedups" in report:
        lines.extend(
            [
                "## Measured FPGA speedup",
                "",
                "| Workload | Speedup | Target | Result |",
                "|---|---:|---:|---|",
            ]
        )
        for name, target in TARGET_SPEEDUPS.items():
            measured = report["speedups"][name]
            result = "PASS" if measured > target else "FAIL"
            lines.append(
                f"| {name} | {measured:.2f}x | >{target:.0f}x | {result} |"
            )
    else:
        lines.extend(
            [
                "## FPGA measurement",
                "",
                "Not supplied. Run again with `--fpga-results timings.json`.",
                "The timing JSON must contain `tanimoto_ms`, `gnn_ms`, "
                "`admet_ms`, and `end_to_end_ms`.",
            ]
        )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20260723)
    parser.add_argument("--molecules", type=int, default=1000)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--fpga-results", type=Path)
    parser.add_argument(
        "--output-json",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "reports"
        / "benchmark_results.json",
    )
    parser.add_argument(
        "--output-md",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "reports"
        / "benchmark_results.md",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="use 100 molecules and 2 repeats for a fast smoke test",
    )
    args = parser.parse_args()
    if args.quick:
        args.molecules = 100
        args.repeats = 2
    if args.molecules < 1 or args.repeats < 1:
        parser.error("--molecules and --repeats must be positive")
    return args


def main() -> int:
    args = parse_args()
    try:
        report = run_benchmarks(args)
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=__import__("sys").stderr)
        return 2
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_md.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(
        json.dumps(report, indent=2), encoding="utf-8"
    )
    args.output_md.write_text(markdown_report(report), encoding="utf-8")
    print(f"Wrote {args.output_json}")
    print(f"Wrote {args.output_md}")
    if "target_results" in report:
        failures = [
            name
            for name, result in report["target_results"].items()
            if not result["pass"]
        ]
        return 1 if failures else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
