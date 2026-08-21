#!/usr/bin/env python3
"""Behavior tests for the shared RTL/C DMA protocol generator."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "tools" / "generate_dma_protocol.py"
SPEC = ROOT / "protocol" / "mol_dma_protocol.json"


EXPECTED_CONSTANTS = {
    "MAGIC_REQUEST": 0x4D4F4C51,
    "MAGIC_RESPONSE": 0x4D4F4C52,
    "MAGIC_TRAILER": 0x4D4F4C45,
    "VERSION": 1,
    "BATCH_HEADER_WORDS": 8,
    "TASK_HEADER_WORDS": 8,
    "RESULT_HEADER_WORDS": 8,
    "TRAILER_WORDS": 8,
    "MAX_TASKS": 64,
    "MAX_TRANSFER_BYTES": 2 * 1024 * 1024,
    "TASK_TANIMOTO": 0,
    "TASK_GNN": 1,
    "TASK_ADMET": 2,
    "TASK_PIPELINE": 3,
    "TASK_WEIGHT_RELOAD": 0xFE,
    "FLAG_FULL_GNN_OUTPUT": 1 << 8,
    "FLAG_RETURN_INTERMEDIATE": 1 << 9,
    "FLAG_SHARED_QUERY": 1 << 10,
    "STATUS_OK": 0,
    "STATUS_BAD_MAGIC": 1,
    "STATUS_BAD_VERSION": 2,
    "STATUS_BAD_LENGTH": 3,
    "STATUS_BAD_TASK": 4,
    "STATUS_BAD_FLAGS": 5,
    "STATUS_BAD_ITEM_COUNT": 6,
    "STATUS_RESULT_OVERFLOW": 7,
    "STATUS_TASK_TIMEOUT": 8,
    "STATUS_LEGACY_BUSY": 9,
    "STATUS_STREAM_TRUNCATED": 10,
    "STATUS_INTERNAL_ERROR": 11,
    "PAYLOAD_WORDS_WEIGHT_RELOAD": 4538,
}


def parse_verilog_constants(text: str) -> dict[str, int]:
    constants: dict[str, int] = {}
    pattern = re.compile(
        r"^`define\s+MOL_DMA_([A-Z0-9_]+)\s+(?:32'h([0-9A-Fa-f]+)|(\d+))$",
        re.MULTILINE,
    )
    for name, hex_value, decimal_value in pattern.findall(text):
        constants[name] = int(hex_value, 16) if hex_value else int(decimal_value)
    return constants


def parse_c_constants(text: str) -> dict[str, int]:
    constants: dict[str, int] = {}
    pattern = re.compile(
        r"^#define\s+MOL_DMA_([A-Z0-9_]+)\s+"
        r"(?:UINT32_C\(0x([0-9A-Fa-f]+)\)|UINT32_C\((\d+)\)|(\d+)u?)$",
        re.MULTILINE,
    )
    for name, hex_value, wrapped_decimal, decimal_value in pattern.findall(text):
        raw = hex_value or wrapped_decimal or decimal_value
        constants[name] = int(raw, 16) if hex_value else int(raw)
    return constants


class ProtocolCodegenTests(unittest.TestCase):
    def run_generator(
        self, verilog_out: Path, c_out: Path, *extra: str, spec: Path = SPEC
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--spec",
                str(spec),
                "--verilog-out",
                str(verilog_out),
                "--c-out",
                str(c_out),
                *extra,
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_generates_matching_verilog_and_c_wire_contract(self) -> None:
        """Catches a missing/wrong constant or disagreement between RTL and software."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            verilog_out = temporary / "mol_dma_protocol.vh"
            c_out = temporary / "mol_dma_protocol.h"

            completed = self.run_generator(verilog_out, c_out)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            verilog_constants = parse_verilog_constants(
                verilog_out.read_text(encoding="utf-8")
            )
            c_constants = parse_c_constants(c_out.read_text(encoding="utf-8"))
            for name, expected in EXPECTED_CONSTANTS.items():
                self.assertEqual(verilog_constants.get(name), expected, name)
                self.assertEqual(c_constants.get(name), expected, name)

            c_header = c_out.read_text(encoding="utf-8")
            self.assertIn("mol_dma_batch_header_t", c_header)
            self.assertIn("mol_dma_task_header_t", c_header)
            self.assertIn("mol_dma_result_header_t", c_header)
            self.assertIn("mol_dma_trailer_t", c_header)
            self.assertEqual(c_header.count("sizeof("), 4)

    def test_v2_batch_limits_and_weight_reload_contract(self) -> None:
        """Catches stale v1 batch limits or missing reload CRC/epoch semantics."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            verilog_out = temporary / "mol_dma_protocol.vh"
            c_out = temporary / "mol_dma_protocol.h"

            completed = self.run_generator(verilog_out, c_out)

            self.assertEqual(completed.returncode, 0, completed.stdout)
            rtl = verilog_out.read_text(encoding="utf-8")
            c_header = c_out.read_text(encoding="utf-8")
            spec = json.loads(SPEC.read_text(encoding="utf-8"))
            self.assertIn("`define MOL_DMA_MAX_ITEM_COUNT 128", rtl)
            self.assertIn("#define MOL_DMA_MAX_ITEM_COUNT UINT32_C(128)", c_header)
            self.assertIn("`define MOL_DMA_MAX_TASKS 64", rtl)
            self.assertIn("#define MOL_DMA_MAX_TASKS UINT32_C(64)", c_header)
            self.assertIn("`define MOL_DMA_WEIGHT_RELOAD_EXPECTED_CRC_WORD 5", rtl)
            self.assertIn("`define MOL_DMA_WEIGHT_RELOAD_OBSERVED_CRC_WORD 7", rtl)
            self.assertIn("`define MOL_DMA_WEIGHT_RELOAD_RESULT_EPOCH_WORDS 1", rtl)
            self.assertIn("#define MOL_DMA_WEIGHT_RELOAD_EXPECTED_CRC_WORD UINT32_C(5)", c_header)
            self.assertIn("#define MOL_DMA_WEIGHT_RELOAD_OBSERVED_CRC_WORD UINT32_C(7)", c_header)
            self.assertIn("#define MOL_DMA_WEIGHT_RELOAD_RESULT_EPOCH_WORDS UINT32_C(1)", c_header)
            self.assertEqual(spec["weight_reload"]["expected_crc_field"], "user_tag")
            self.assertEqual(spec["weight_reload"]["observed_crc_field"], "detail")
            self.assertEqual(spec["weight_reload"].get("crc32_algorithm"), "ieee")
            self.assertEqual(spec["weight_reload"]["result_epoch_words"], 1)

    def test_rejects_non_v2_frozen_limits(self) -> None:
        """Catches a schema that accepts a limit outside the frozen v2 contract."""
        expected_limits = {
            "max_tasks": 64,
            "max_transfer_bytes": 2097152,
            "max_transfer_words": 524288,
            "max_item_count": 128,
        }
        source_spec = json.loads(SPEC.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            for name, expected in expected_limits.items():
                invalid_spec = json.loads(json.dumps(source_spec))
                invalid_spec["limits"][name] = expected - 1
                spec_path = temporary / f"invalid_{name}.json"
                spec_path.write_text(json.dumps(invalid_spec), encoding="utf-8")

                completed = self.run_generator(
                    temporary / f"{name}.vh",
                    temporary / f"{name}.h",
                    spec=spec_path,
                )

                self.assertNotEqual(completed.returncode, 0, name)
                self.assertIn("protocol limits", completed.stdout.lower(), name)

    def test_rejects_non_ieee_weight_reload_crc32(self) -> None:
        """Catches a weight-reload CRC variant other than the frozen IEEE CRC32."""
        source_spec = json.loads(SPEC.read_text(encoding="utf-8"))
        source_spec["weight_reload"]["crc32_algorithm"] = "crc32c"
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            spec_path = temporary / "invalid_crc32.json"
            spec_path.write_text(json.dumps(source_spec), encoding="utf-8")

            completed = self.run_generator(
                temporary / "protocol.vh", temporary / "protocol.h", spec=spec_path
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("crc32 algorithm", completed.stdout.lower())

    def test_check_mode_rejects_generated_file_drift(self) -> None:
        """Catches hand edits or stale generated protocol headers."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            verilog_out = temporary / "mol_dma_protocol.vh"
            c_out = temporary / "mol_dma_protocol.h"
            generated = self.run_generator(verilog_out, c_out)
            self.assertEqual(generated.returncode, 0, generated.stdout)

            c_out.write_text("stale\n", encoding="utf-8")
            checked = self.run_generator(verilog_out, c_out, "--check")

            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("out of date", checked.stdout.lower())

    def test_regression_runner_exposes_protocol_drift_check(self) -> None:
        """Catches a regression runner that silently skips stale generated headers."""
        completed = subprocess.run(
            [sys.executable, str(ROOT / "sim" / "run_tests.py"), "--test", "protocol"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("protocol generated-file check passed", completed.stdout.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
