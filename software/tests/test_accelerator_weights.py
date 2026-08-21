#!/usr/bin/env python3
"""Host test for deterministic DMA weight-reload packing."""

from __future__ import annotations

import ctypes
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "software" / "baremetal" / "src"
WEIGHT_WORDS = 4538
GNN_VALUES = 8192
ADMET_VALUES_PER_MODEL = 221


class AcceleratorWeightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="accel_weights_")
        temp = pathlib.Path(cls.temp_dir.name)
        (temp / "xil_types.h").write_text(
            "#include <stdint.h>\n"
            "typedef uint32_t u32; typedef uint16_t u16; typedef int16_t s16;\n"
            "typedef uintptr_t UINTPTR;\n",
            encoding="utf-8",
        )
        (temp / "xparameters.h").write_text("\n", encoding="utf-8")
        (temp / "xil_io.h").write_text(
            "#include <stdint.h>\n"
            "static inline void Xil_Out32(uintptr_t a, uint32_t v)"
            "{ (void)a; (void)v; }\n"
            "static inline uint32_t Xil_In32(uintptr_t a)"
            "{ (void)a; return 0; }\n",
            encoding="utf-8",
        )
        (temp / "xil_printf.h").write_text(
            "static inline int xil_printf(const char *f, ...)"
            "{ (void)f; return 0; }\n",
            encoding="utf-8",
        )
        cls.library = temp / "accelerator.dll"
        subprocess.run(
            [
                "gcc", "-shared", "-std=c11", "-Wall", "-Wextra", "-Werror",
                f"-I{temp}", f"-I{SRC}", str(SRC / "accelerator.c"),
                "-o", str(cls.library),
            ],
            check=True,
            cwd=ROOT,
        )
        cls.lib = ctypes.CDLL(str(cls.library))
        cls.lib.accel_pack_reference_weights.argtypes = [
            ctypes.POINTER(ctypes.c_uint32)
        ]

    @classmethod
    def tearDownClass(cls) -> None:
        ctypes.windll.kernel32.FreeLibrary(cls.lib._handle)
        cls.lib = None
        cls.temp_dir.cleanup()

    def test_reference_weights_are_halfword_packed_low_first(self) -> None:
        words = (ctypes.c_uint32 * WEIGHT_WORDS)()
        self.lib.accel_pack_reference_weights(words)
        halfwords = []
        for word in words:
            halfwords.extend((word & 0xFFFF, word >> 16))

        expected_nonzero = {0}
        for model in range(4):
            model_base = GNN_VALUES + model * ADMET_VALUES_PER_MODEL
            expected_nonzero.add(model_base)
            expected_nonzero.add(model_base + 210)

        actual_nonzero = {
            index for index, value in enumerate(halfwords) if value != 0
        }
        self.assertEqual(actual_nonzero, expected_nonzero)
        for index in expected_nonzero:
            self.assertEqual(halfwords[index], 0x0100)


if __name__ == "__main__":
    unittest.main(verbosity=2)
