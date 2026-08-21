#!/usr/bin/env python3
"""Host golden-vector tests for the MolRecommender DMA wire layout."""

from __future__ import annotations

import ctypes
import pathlib
import struct
import subprocess
import tempfile
import unittest
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "software" / "baremetal" / "src"
VERSION_HEADER = 1 | (8 << 16)
MOLQ = 0x4D4F4C51
MOLR = 0x4D4F4C52
MOLE = 0x4D4F4C45

OK = 0
ERR_ALIGN = -2
ERR_RANGE = -3
ERR_STATE = -4
ERR_FORMAT = -5

TANIMOTO = 0
GNN = 1
ADMET = 2
PIPELINE = 3
WEIGHT_RELOAD = 0xFE
FULL_GNN = 0x100
INTERMEDIATE = 0x200
SHARED_QUERY = 0x400


class Builder(ctypes.Structure):
    _fields_ = [
        ("buffer", ctypes.c_void_p),
        ("capacity_bytes", ctypes.c_size_t),
        ("used_words", ctypes.c_uint32),
        ("task_count", ctypes.c_uint32),
        ("batch_id", ctypes.c_uint32),
        ("batch_flags", ctypes.c_uint32),
        ("max_result_words", ctypes.c_uint32),
        ("reserved_result_words", ctypes.c_uint32),
        ("finalized", ctypes.c_uint32),
    ]


class ResultView(ctypes.Structure):
    _fields_ = [
        ("job_id", ctypes.c_uint32),
        ("task_id", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("result_words", ctypes.c_uint32),
        ("compute_cycles", ctypes.c_uint64),
        ("item_count", ctypes.c_uint32),
        ("user_tag", ctypes.c_uint32),
        ("detail", ctypes.c_uint32),
        ("payload", ctypes.c_void_p),
    ]


class ResultIterator(ctypes.Structure):
    _fields_ = [
        ("buffer", ctypes.c_void_p),
        ("total_words", ctypes.c_uint32),
        ("cursor_words", ctypes.c_uint32),
        ("trailer_word", ctypes.c_uint32),
        ("batch_id", ctypes.c_uint32),
        ("expected_task_count", ctypes.c_uint32),
        ("completed_count", ctypes.c_uint32),
        ("records_seen", ctypes.c_uint32),
    ]


class IrqState(ctypes.Structure):
    _fields_ = [
        ("mm2s_done", ctypes.c_uint32),
        ("s2mm_done", ctypes.c_uint32),
        ("error", ctypes.c_uint32),
    ]


def aligned_buffer(size: int) -> tuple[ctypes.Array, int]:
    raw = ctypes.create_string_buffer(size + 63)
    address = (ctypes.addressof(raw) + 63) & ~63
    return raw, address


def words(values: list[int]) -> ctypes.Array:
    return (ctypes.c_uint32 * len(values))(*values)


def task_requirements(task_id: int, flags: int, count: int) -> tuple[int, int]:
    if task_id == TANIMOTO:
        return ((32 + 32 * count, count) if flags & SHARED_QUERY else (64, 1))
    if task_id == GNN:
        return 1679 * count, (3200 if flags & FULL_GNN else 1) * count
    if task_id == ADMET:
        return 20 * count, 4 * count
    if task_id == WEIGHT_RELOAD:
        if flags != 0 or count != 1:
            raise ValueError("invalid reload request")
        return 4538, 1
    if flags & FULL_GNN:
        return 1763 * count, 3205 * count
    if flags & INTERMEDIATE:
        return 1763 * count, 6 * count
    return 1763 * count, 4 * count


class MolDmaLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="mol_dma_layout_")
        cls.dll = pathlib.Path(cls.temp_dir.name) / "mol_dma_queue.dll"
        subprocess.run(
            [
                "gcc",
                "-shared",
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-DMOL_DMA_HOST_TEST",
                f"-I{SRC}",
                str(SRC / "mol_dma_queue.c"),
                "-o",
                str(cls.dll),
            ],
            check=True,
            cwd=ROOT,
        )
        cls.lib = ctypes.CDLL(str(cls.dll))
        cls.lib.mol_dma_builder_init.argtypes = [
            ctypes.POINTER(Builder), ctypes.c_void_p, ctypes.c_size_t,
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ]
        cls.lib.mol_dma_builder_add_task.argtypes = [
            ctypes.POINTER(Builder), ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_uint32, ctypes.c_uint32,
        ]
        cls.lib.mol_dma_builder_finalize.argtypes = [
            ctypes.POINTER(Builder), ctypes.POINTER(ctypes.c_size_t)
        ]
        cls.lib.mol_dma_results_open.argtypes = [
            ctypes.POINTER(ResultIterator), ctypes.c_void_p, ctypes.c_size_t,
            ctypes.c_uint32,
        ]
        cls.lib.mol_dma_results_next.argtypes = [
            ctypes.POINTER(ResultIterator), ctypes.POINTER(ResultView)
        ]
        cls.lib.mol_dma_find_response_bytes.argtypes = [
            ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_size_t),
        ]

    @classmethod
    def tearDownClass(cls) -> None:
        ctypes.windll.kernel32.FreeLibrary(cls.lib._handle)
        cls.lib = None
        cls.temp_dir.cleanup()

    def new_builder(self, capacity: int = 2 * 1024 * 1024,
                    batch_id: int = 0x12345678,
                    max_result_words: int = 200000) -> tuple[ctypes.Array, int, Builder]:
        raw, address = aligned_buffer(capacity)
        builder = Builder()
        rc = self.lib.mol_dma_builder_init(
            ctypes.byref(builder), address, capacity, batch_id, 1,
            max_result_words,
        )
        self.assertEqual(rc, OK)
        return raw, address, builder

    def add_task(self, builder: Builder, job_id: int, task_id: int,
                 flags: int, item_count: int, user_tag: int = 0xA5000000,
                 result_capacity: int | None = None) -> list[int]:
        payload_count, required_result = task_requirements(task_id, flags, item_count)
        payload = [(job_id << 20) ^ index for index in range(payload_count)]
        payload_array = words(payload)
        capacity = required_result if result_capacity is None else result_capacity
        rc = self.lib.mol_dma_builder_add_task(
            ctypes.byref(builder), job_id, task_id, flags, item_count,
            user_tag ^ job_id, 100000 + job_id, payload_array,
            payload_count, capacity,
        )
        self.assertEqual(rc, OK)
        return payload

    def test_empty_rejection_and_alignment(self) -> None:
        raw, address = aligned_buffer(4096)
        builder = Builder()
        self.assertEqual(
            self.lib.mol_dma_builder_init(
                ctypes.byref(builder), address + 4, 4096, 1, 0, 64
            ),
            ERR_ALIGN,
        )
        self.assertEqual(
            self.lib.mol_dma_builder_init(
                ctypes.byref(builder), address, 4096, 1, 0, 64
            ),
            OK,
        )
        size = ctypes.c_size_t()
        self.assertEqual(
            self.lib.mol_dma_builder_finalize(ctypes.byref(builder), ctypes.byref(size)),
            ERR_STATE,
        )
        self.assertIsNotNone(raw)

    def test_irq_state_requires_both_channels_and_latches_errors(self) -> None:
        self.assertTrue(
            hasattr(self.lib, "mol_dma_irq_record"),
            "mol_dma_irq_record is missing",
        )
        self.assertTrue(
            hasattr(self.lib, "mol_dma_irq_complete"),
            "mol_dma_irq_complete is missing",
        )
        record = self.lib.mol_dma_irq_record
        record.argtypes = [
            ctypes.POINTER(IrqState), ctypes.c_uint32, ctypes.c_uint32
        ]
        complete = self.lib.mol_dma_irq_complete
        complete.argtypes = [ctypes.POINTER(IrqState)]
        complete.restype = ctypes.c_int

        state = IrqState()
        record(ctypes.byref(state), 0, 1)
        self.assertEqual((state.mm2s_done, state.s2mm_done, state.error),
                         (1, 0, 0))
        self.assertEqual(complete(ctypes.byref(state)), 0)
        record(ctypes.byref(state), 1, 1)
        self.assertEqual(complete(ctypes.byref(state)), 1)

        failed = IrqState()
        record(ctypes.byref(failed), 1, 2)
        self.assertEqual((failed.mm2s_done, failed.s2mm_done, failed.error),
                         (0, 0, 1))
        self.assertEqual(complete(ctypes.byref(failed)), 0)

    def test_byte_exact_one_task_of_each_type(self) -> None:
        for task_id, flags, count in [
            (TANIMOTO, 0, 1),
            (GNN, 0, 1),
            (ADMET, 0, 4),
            (PIPELINE, INTERMEDIATE, 1),
            (WEIGHT_RELOAD, 0, 1),
        ]:
            with self.subTest(task=task_id):
                raw, address, builder = self.new_builder(batch_id=0x10203040)
                payload = self.add_task(builder, 7, task_id, flags, count)
                byte_count = ctypes.c_size_t()
                self.assertEqual(
                    self.lib.mol_dma_builder_finalize(
                        ctypes.byref(builder), ctypes.byref(byte_count)
                    ), OK
                )
                result_words = task_requirements(task_id, flags, count)[1]
                expected_words = [
                    MOLQ, VERSION_HEADER, 0x10203040, 1,
                    8 + 8 + len(payload), 1, 200000, 0,
                    7, task_id | flags, len(payload), result_words,
                    count, 0xA5000000 ^ 7, 100007, 0,
                    *payload,
                ]
                expected = struct.pack(f"<{len(expected_words)}I", *expected_words)
                self.assertEqual(byte_count.value, len(expected))
                self.assertEqual(ctypes.string_at(address, byte_count.value), expected)
                self.assertIsNotNone(raw)

    def test_all_flags_and_maximum_buffer_bounds(self) -> None:
        cases = [
            (TANIMOTO, SHARED_QUERY, 64),
            (GNN, FULL_GNN, 1),
            (PIPELINE, INTERMEDIATE, 1),
            (PIPELINE, FULL_GNN, 1),
            (PIPELINE, FULL_GNN | INTERMEDIATE, 1),
        ]
        for index, case in enumerate(cases):
            raw, _, builder = self.new_builder(batch_id=index + 1)
            self.add_task(builder, index + 1, *case)
            size = ctypes.c_size_t()
            self.assertEqual(
                self.lib.mol_dma_builder_finalize(ctypes.byref(builder), ctypes.byref(size)),
                OK,
            )
            self.assertLessEqual(size.value, 2 * 1024 * 1024)
            self.assertIsNotNone(raw)

        raw, _, builder = self.new_builder(capacity=128, max_result_words=64)
        payload = words([0] * 64)
        before = builder.used_words
        rc = self.lib.mol_dma_builder_add_task(
            ctypes.byref(builder), 1, TANIMOTO, 0, 1, 0, 1,
            payload, 64, 1,
        )
        self.assertEqual(rc, ERR_RANGE)
        self.assertEqual(builder.used_words, before)
        self.assertIsNotNone(raw)

    @staticmethod
    def batched_success_frame(task_id: int, item_count: int,
                              result_words: int) -> bytes:
        body = [7, task_id, result_words, 1, 0, item_count, 0xA5, 0]
        body.extend([0] * result_words)
        total_words = 8 + len(body) + 8
        return struct.pack(
            f"<{total_words}I",
            MOLR, VERSION_HEADER, 0xBA7C0001, 1, 0, total_words, 0, 0,
            *body,
            MOLE, 0xBA7C0001, 1, 0, total_words, 0, 0xFFFFFFFF, 0,
        )

    def test_batched_gnn_and_pipeline_builder_and_parser(self) -> None:
        cases = [
            (GNN, 0, 16), (GNN, 0, 32), (GNN, FULL_GNN, 32),
            (PIPELINE, 0, 8), (PIPELINE, 0, 16), (PIPELINE, INTERMEDIATE, 16),
            (PIPELINE, FULL_GNN | INTERMEDIATE, 16),
        ]
        for task_id, flags, item_count in cases:
            with self.subTest(task=task_id, flags=flags, count=item_count):
                raw, address, builder = self.new_builder(max_result_words=200000)
                self.add_task(builder, 7, task_id, flags, item_count)
                transfer_bytes = ctypes.c_size_t()
                self.assertEqual(
                    self.lib.mol_dma_builder_finalize(
                        ctypes.byref(builder), ctypes.byref(transfer_bytes)
                    ), OK
                )
                payload_words, result_words = task_requirements(
                    task_id, flags, item_count
                )
                header = struct.unpack_from("<8I", ctypes.string_at(address, transfer_bytes.value), 0)
                task_header = struct.unpack_from("<8I", ctypes.string_at(address, transfer_bytes.value), 32)
                self.assertEqual((header[4], task_header[2], task_header[3], task_header[4]),
                                 (8 + 8 + payload_words, payload_words,
                                  result_words, item_count))

                frame = self.batched_success_frame(task_id, item_count, result_words)
                response_raw, response_address = aligned_buffer(len(frame))
                ctypes.memmove(response_address, frame, len(frame))
                iterator = ResultIterator()
                self.assertEqual(self.lib.mol_dma_results_open(
                    ctypes.byref(iterator), response_address, len(frame), 0xBA7C0001
                ), OK)
                view = ResultView()
                self.assertEqual(self.lib.mol_dma_results_next(
                    ctypes.byref(iterator), ctypes.byref(view)), 1)
                self.assertEqual((view.task_id, view.item_count, view.result_words),
                                 (task_id, item_count, result_words))
                self.assertIsNotNone(raw)
                self.assertIsNotNone(response_raw)

        for task_id, item_count in ((GNN, 33), (PIPELINE, 17)):
            with self.subTest(rejected_task=task_id, count=item_count):
                raw, _, builder = self.new_builder()
                payload = words([0])
                self.assertLess(self.lib.mol_dma_builder_add_task(
                    ctypes.byref(builder), 1, task_id, 0, item_count,
                    0, 1, payload, 1, 1
                ), 0)
                self.assertIsNotNone(raw)

    def test_result_parser_accepts_weight_reload_success(self) -> None:
        total_words = 8 + 8 + 1 + 8
        frame_words = [
            MOLR, VERSION_HEADER, 0xFEED0001, 1, 0, total_words, 0, 0,
            9, WEIGHT_RELOAD, 1, 100, 0, 1, 0xCAFE, 0xCAFE, 7,
            MOLE, 0xFEED0001, 1, 0, total_words, 0, 0xFFFFFFFF, 0,
        ]
        frame = struct.pack(f"<{len(frame_words)}I", *frame_words)
        raw, address = aligned_buffer(len(frame))
        ctypes.memmove(address, frame, len(frame))
        iterator = ResultIterator()
        self.assertEqual(
            self.lib.mol_dma_results_open(
                ctypes.byref(iterator), address, len(frame), 0xFEED0001
            ),
            OK,
        )
        view = ResultView()
        self.assertEqual(
            self.lib.mol_dma_results_next(ctypes.byref(iterator), ctypes.byref(view)),
            1,
        )
        self.assertEqual((view.task_id, view.result_words), (WEIGHT_RELOAD, 1))
        self.assertEqual(ctypes.c_uint32.from_address(view.payload).value, 7)
        parse_reload = self.lib.mol_dma_weight_reload_result
        parse_reload.argtypes = [
            ctypes.POINTER(ResultView), ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        epoch = ctypes.c_uint32()
        observed = ctypes.c_uint32()
        self.assertEqual(parse_reload(
            ctypes.byref(view), ctypes.byref(epoch), ctypes.byref(observed)
        ), OK)
        self.assertEqual((epoch.value, observed.value), (7, 0xCAFE))
        self.assertIsNotNone(raw)

    def test_crc32_words_matches_zlib_little_endian(self) -> None:
        values = [0x12345678, 0x00FF80A5, 0xDEADBEEF, 0x01020304]
        payload = words(values)
        crc32_words = self.lib.mol_dma_crc32_words
        crc32_words.argtypes = [ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32]
        crc32_words.restype = ctypes.c_uint32
        expected = zlib.crc32(struct.pack("<4I", *values)) & 0xFFFFFFFF
        self.assertEqual(expected, 0x8D97155C)
        self.assertEqual(crc32_words(payload, len(values)), expected)

    def test_reload_builder_writes_computed_crc_to_user_tag(self) -> None:
        raw, address, builder = self.new_builder()
        values = [((index * 0x00010203) ^ 0xA5C30000) & 0xFFFFFFFF
                  for index in range(4538)]
        payload = words(values)
        add_reload = self.lib.mol_dma_builder_add_weight_reload
        add_reload.argtypes = [
            ctypes.POINTER(Builder), ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32,
            ctypes.c_uint32,
        ]
        self.assertEqual(add_reload(
            ctypes.byref(builder), 77, payload, len(values), 900000
        ), OK)
        header = struct.unpack_from("<8I", ctypes.string_at(address, 64), 32)
        expected = zlib.crc32(struct.pack(f"<{len(values)}I", *values)) & 0xFFFFFFFF
        self.assertEqual((header[0], header[1] & 0xFF, header[5]),
                         (77, WEIGHT_RELOAD, expected))
        self.assertIsNotNone(raw)

    def test_bad_reload_result_returns_observed_crc_and_unchanged_epoch(self) -> None:
        expected_crc = 0x7207BAB4
        observed_crc = 0x743FA3C3
        epoch = 1
        total_words = 8 + 8 + 1 + 8
        frame_words = [
            MOLR, VERSION_HEADER, 0xFEED0002, 1, 0, total_words, 0, 0,
            9, WEIGHT_RELOAD | (11 << 8), 1, 100, 0, 1,
            expected_crc, observed_crc, epoch,
            MOLE, 0xFEED0002, 1, 1, total_words, 11, 9, 0,
        ]
        frame = struct.pack(f"<{len(frame_words)}I", *frame_words)
        raw, address = aligned_buffer(len(frame))
        ctypes.memmove(address, frame, len(frame))
        iterator = ResultIterator()
        self.assertEqual(self.lib.mol_dma_results_open(
            ctypes.byref(iterator), address, len(frame), 0xFEED0002
        ), OK)
        view = ResultView()
        self.assertEqual(self.lib.mol_dma_results_next(
            ctypes.byref(iterator), ctypes.byref(view)
        ), 1)
        parse_reload = self.lib.mol_dma_weight_reload_result
        parse_reload.argtypes = [
            ctypes.POINTER(ResultView), ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        new_epoch = ctypes.c_uint32()
        observed = ctypes.c_uint32()
        self.assertEqual(parse_reload(
            ctypes.byref(view), ctypes.byref(new_epoch), ctypes.byref(observed)
        ), -6)
        self.assertEqual((new_epoch.value, observed.value), (epoch, observed_crc))
        self.assertIsNotNone(raw)

    def test_64_mixed_tasks(self) -> None:
        raw, address, builder = self.new_builder(max_result_words=300000)
        choices = [
            (TANIMOTO, 0, 1),
            (GNN, 0, 1),
            (ADMET, 0, 1),
            (PIPELINE, 0, 1),
        ]
        for job_id in range(64):
            self.add_task(builder, job_id + 1, *choices[job_id % 4])
        size = ctypes.c_size_t()
        self.assertEqual(
            self.lib.mol_dma_builder_finalize(ctypes.byref(builder), ctypes.byref(size)),
            OK,
        )
        header = struct.unpack_from("<8I", ctypes.string_at(address, size.value))
        self.assertEqual(header[3], 64)
        self.assertEqual(header[4] * 4, size.value)
        self.assertIsNotNone(raw)

    @staticmethod
    def response_frame() -> bytes:
        records = [
            (11, TANIMOTO, 0, [0x10000], 10, 1, 0xAA, 0),
            (12, GNN, 0, [0x100], 20, 1, 0xBB, 0),
            (13, ADMET, 0, [187, 187, 187, 187], 30, 1, 0xCC, 0),
            (14, PIPELINE, 0, [187, 187, 187, 187], 40, 1, 0xDD, 0),
        ]
        body: list[int] = []
        for job, task, status, payload, cycles, count, tag, detail in records:
            body.extend([
                job, task | (status << 8), len(payload), cycles, 0,
                count, tag, detail, *payload,
            ])
        total_words = 8 + len(body) + 8
        all_words = [
            MOLR, VERSION_HEADER, 0x55AA55AA, 4, 0, total_words, 0, 0,
            *body,
            MOLE, 0x55AA55AA, 4, 0, total_words, 0, 0xFFFFFFFF, 0,
        ]
        return struct.pack(f"<{len(all_words)}I", *all_words)

    def test_result_parser_and_trailer_discovery(self) -> None:
        frame = self.response_frame()
        raw, address = aligned_buffer(len(frame) + 256)
        ctypes.memset(address, 0, len(frame) + 256)
        ctypes.memmove(address, frame, len(frame))

        found = ctypes.c_size_t()
        self.assertEqual(
            self.lib.mol_dma_find_response_bytes(
                address, len(frame) + 256, 0x55AA55AA, ctypes.byref(found)
            ), OK
        )
        self.assertEqual(found.value, len(frame))

        iterator = ResultIterator()
        self.assertEqual(
            self.lib.mol_dma_results_open(
                ctypes.byref(iterator), address, len(frame), 0x55AA55AA
            ), OK
        )
        jobs = []
        view = ResultView()
        while True:
            rc = self.lib.mol_dma_results_next(ctypes.byref(iterator), ctypes.byref(view))
            if rc == 0:
                break
            self.assertEqual(rc, 1)
            jobs.append((view.job_id, view.task_id, view.user_tag, view.result_words))
        self.assertEqual(
            jobs,
            [(11, 0, 0xAA, 1), (12, 1, 0xBB, 1),
             (13, 2, 0xCC, 4), (14, 3, 0xDD, 4)],
        )
        self.assertIsNotNone(raw)

    def test_result_parser_rejects_corruption_and_trailing_data(self) -> None:
        frame = bytearray(self.response_frame())
        mutations = []
        bad_magic = bytearray(frame)
        struct.pack_into("<I", bad_magic, 0, 0)
        mutations.append(bad_magic)
        bad_trailer_count = bytearray(frame)
        struct.pack_into("<I", bad_trailer_count, len(frame) - 24, 3)
        mutations.append(bad_trailer_count)
        bad_total = bytearray(frame)
        struct.pack_into("<I", bad_total, len(frame) - 16, 1)
        mutations.append(bad_total)
        mutations.append(frame + b"\x00\x00\x00\x00")

        for damaged in mutations:
            raw, address = aligned_buffer(len(damaged))
            ctypes.memmove(address, bytes(damaged), len(damaged))
            iterator = ResultIterator()
            self.assertEqual(
                self.lib.mol_dma_results_open(
                    ctypes.byref(iterator), address, len(damaged), 0x55AA55AA
                ), ERR_FORMAT
            )
            self.assertIsNotNone(raw)

    def test_result_parser_accepts_echoed_invalid_task_fields(self) -> None:
        body = [
            21, 0x7F | (4 << 8), 0, 5, 0, 1, 0x1111, 0,
            22, ADMET | (6 << 8), 0, 6, 0, 65, 0x2222, 0,
        ]
        total_words = 8 + len(body) + 8
        frame_words = [
            MOLR, VERSION_HEADER, 0xABCDEF01, 2, 0, total_words, 0, 0,
            *body,
            MOLE, 0xABCDEF01, 2, 2, total_words, 4, 21, 0,
        ]
        frame = struct.pack(f"<{len(frame_words)}I", *frame_words)
        raw, address = aligned_buffer(len(frame))
        ctypes.memmove(address, frame, len(frame))
        iterator = ResultIterator()
        self.assertEqual(
            self.lib.mol_dma_results_open(
                ctypes.byref(iterator), address, len(frame), 0xABCDEF01
            ), OK
        )
        view = ResultView()
        self.assertEqual(
            self.lib.mol_dma_results_next(ctypes.byref(iterator), ctypes.byref(view)),
            1,
        )
        self.assertEqual((view.task_id, view.status), (0x7F, 4))
        self.assertIsNotNone(raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
