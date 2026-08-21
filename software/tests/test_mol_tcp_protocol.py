#!/usr/bin/env python3
"""Host tests for the 16-byte TCP frame codec, stream parser and FIFO."""

from __future__ import annotations

import ctypes
import pathlib
import struct
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "software" / "baremetal" / "src"
HEADER_BYTES = 16
SLOT_BYTES = 256 * 1024
QUEUE_DEPTH = 8
OK = 0
BUSY = 1
FRAME_READY = 1
NEED_MORE = 0


class Header(ctypes.Structure):
    _fields_ = [
        ("task_id", ctypes.c_uint8),
        ("flags", ctypes.c_uint8),
        ("_padding", ctypes.c_uint16),
        ("payload_len", ctypes.c_uint32),
        ("trace_id", ctypes.c_uint32),
        ("batch_size", ctypes.c_uint32),
    ]


class Stream(ctypes.Structure):
    _fields_ = [
        ("header_bytes", ctypes.c_uint8 * HEADER_BYTES),
        ("header_used", ctypes.c_uint32),
        ("header", Header),
        ("payload", ctypes.c_uint8 * SLOT_BYTES),
        ("payload_used", ctypes.c_uint32),
        ("have_header", ctypes.c_uint32),
    ]


class Request(ctypes.Structure):
    _fields_ = [
        ("header", Header),
        ("connection_slot", ctypes.c_uint32),
        ("connection_generation", ctypes.c_uint32),
        ("payload_len", ctypes.c_uint32),
        ("payload", ctypes.c_uint8 * SLOT_BYTES),
    ]


class Queue(ctypes.Structure):
    _fields_ = [
        ("slots", Request * QUEUE_DEPTH),
        ("head", ctypes.c_uint32),
        ("tail", ctypes.c_uint32),
        ("count", ctypes.c_uint32),
    ]


def request_header(task_id: int, payload_len: int, trace: int,
                   batch: int, flags: int = 0) -> bytes:
    return struct.pack("<BBBBIII", 0x5A, 1, task_id, flags,
                       payload_len, trace, batch)


class MolTcpProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="mol_tcp_protocol_")
        cls.library = pathlib.Path(cls.temp_dir.name) / "mol_tcp_protocol.dll"
        cls.source = SRC / "mol_tcp_protocol.c"
        cls.lib = None
        if not cls.source.exists():
            return
        subprocess.run(
            [
                "gcc", "-shared", "-std=c11", "-Wall", "-Wextra", "-Werror",
                f"-I{SRC}", str(cls.source),
                "-o", str(cls.library),
            ],
            check=True,
            cwd=ROOT,
        )
        cls.lib = ctypes.CDLL(str(cls.library))
        cls.lib.mol_tcp_decode_header.argtypes = [
            ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(Header)
        ]
        cls.lib.mol_tcp_encode_header.argtypes = [
            ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(Header)
        ]
        cls.lib.mol_tcp_dma_shape.argtypes = [
            ctypes.c_uint8, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32),
        ]
        cls.lib.mol_tcp_stream_init.argtypes = [ctypes.POINTER(Stream)]
        cls.lib.mol_tcp_stream_feed.argtypes = [
            ctypes.POINTER(Stream), ctypes.POINTER(ctypes.c_uint8),
            ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t),
        ]
        cls.lib.mol_tcp_queue_init.argtypes = [ctypes.POINTER(Queue)]
        cls.lib.mol_tcp_request_queue_push.argtypes = [
            ctypes.POINTER(Queue), ctypes.POINTER(Header),
            ctypes.c_uint32, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32,
        ]
        cls.lib.mol_tcp_request_queue_pop.argtypes = [
            ctypes.POINTER(Queue), ctypes.POINTER(Request)
        ]

    def setUp(self) -> None:
        self.assertIsNotNone(self.lib, "mol_tcp_protocol.c is missing")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.lib is not None:
            ctypes.windll.kernel32.FreeLibrary(cls.lib._handle)
            cls.lib = None
        cls.temp_dir.cleanup()

    @staticmethod
    def byte_array(data: bytes) -> ctypes.Array:
        return (ctypes.c_uint8 * len(data)).from_buffer_copy(data)

    def decode(self, data: bytes) -> tuple[int, Header]:
        header = Header()
        raw = self.byte_array(data)
        return self.lib.mol_tcp_decode_header(raw, ctypes.byref(header)), header

    def test_golden_header_and_dma_shapes(self) -> None:
        golden = bytes.fromhex(
            "5a 01 00 00 00 01 00 00 78 56 34 12 01 00 00 00"
        )
        rc, header = self.decode(golden)
        self.assertEqual(rc, OK)
        self.assertEqual(
            (header.task_id, header.flags, header.payload_len,
             header.trace_id, header.batch_size),
            (0, 0, 256, 0x12345678, 1),
        )
        encoded = (ctypes.c_uint8 * HEADER_BYTES)()
        self.assertEqual(
            self.lib.mol_tcp_encode_header(encoded, ctypes.byref(header)), OK
        )
        self.assertEqual(bytes(encoded), golden)

        shapes = [
            (0, 1, 0, 64, 1),
            (0, 128, 0x400, 4128, 128),
            (1, 1, 0, 1679, 1),
            (1, 16, 0, 26864, 16),
            (1, 32, 0, 53728, 32),
            (2, 64, 0, 1280, 256),
            (3, 8, 0, 14104, 32),
            (3, 16, 0, 28208, 64),
            (0xFE, 1, 0, 4538, 1),
        ]
        for task, batch, expected_flags, expected_payload, expected_result in shapes:
            flags = ctypes.c_uint32()
            item_count = ctypes.c_uint32()
            payload = ctypes.c_uint32()
            result = ctypes.c_uint32()
            self.assertEqual(
                self.lib.mol_tcp_dma_shape(
                    task, batch, ctypes.byref(flags), ctypes.byref(item_count),
                    ctypes.byref(payload), ctypes.byref(result)
                ),
                OK,
            )
            self.assertEqual(
                (flags.value, item_count.value, payload.value, result.value),
                (expected_flags, batch, expected_payload, expected_result),
            )

    def test_status_request_is_local_and_slot_overflow_is_rejected(self) -> None:
        rc, header = self.decode(request_header(0xFD, 0, 11, 1))
        self.assertEqual(rc, OK)
        self.assertEqual((header.task_id, header.payload_len, header.batch_size),
                         (0xFD, 0, 1))
        oversized = Header(0, 0, 0, SLOT_BYTES + 4, 12, 1)
        encoded = (ctypes.c_uint8 * HEADER_BYTES)()
        rc = self.lib.mol_tcp_encode_header(encoded, ctypes.byref(oversized))
        self.assertLess(rc, 0)

    def test_header_rejects_bad_contract_fields(self) -> None:
        valid = bytearray(request_header(0, 256, 7, 1))
        mutations = []
        for offset, value in [(0, 0), (1, 2), (3, 1)]:
            changed = bytearray(valid)
            changed[offset] = value
            mutations.append(changed)
        mutations.extend([
            request_header(0x7F, 4, 7, 1),
            request_header(0, 252, 7, 1),
            request_header(1, 1679 * 4, 7, 2),
            request_header(2, 0, 7, 0),
            request_header(2, 20 * 65 * 4, 7, 65),
            request_header(0xFE, 18148, 7, 1),
        ])
        for damaged in mutations:
            with self.subTest(frame=bytes(damaged).hex()):
                rc, _ = self.decode(bytes(damaged))
                self.assertLess(rc, 0)

    def test_stream_parser_handles_split_and_coalesced_frames(self) -> None:
        payload = bytes((index & 0xFF) for index in range(256))
        frame = request_header(0, len(payload), 0x101, 1) + payload
        stream = Stream()
        self.lib.mol_tcp_stream_init(ctypes.byref(stream))
        cursor = 0
        for chunk_size in (1, 3, 12, 7, 51, len(frame)):
            if cursor == len(frame):
                break
            chunk = frame[cursor:cursor + chunk_size]
            raw = self.byte_array(chunk)
            consumed = ctypes.c_size_t()
            rc = self.lib.mol_tcp_stream_feed(
                ctypes.byref(stream), raw, len(chunk), ctypes.byref(consumed)
            )
            self.assertEqual(consumed.value, len(chunk))
            cursor += len(chunk)
            self.assertEqual(rc, FRAME_READY if cursor == len(frame) else NEED_MORE)
        self.assertEqual(bytes(stream.payload[:stream.payload_used]), payload)

        second = request_header(0, 256, 0x202, 1) + bytes(256)
        joined = frame + second
        self.lib.mol_tcp_stream_init(ctypes.byref(stream))
        raw = self.byte_array(joined)
        consumed = ctypes.c_size_t()
        self.assertEqual(
            self.lib.mol_tcp_stream_feed(
                ctypes.byref(stream), raw, len(joined), ctypes.byref(consumed)
            ),
            FRAME_READY,
        )
        self.assertEqual(consumed.value, len(frame))

    def test_queue_is_fifo_and_returns_busy_at_depth_eight(self) -> None:
        queue = Queue()
        self.lib.mol_tcp_queue_init(ctypes.byref(queue))
        payload = self.byte_array(bytes(256))
        for trace in range(QUEUE_DEPTH):
            header = Header(0, 0, 0, 256, trace, 1)
            self.assertEqual(
                self.lib.mol_tcp_request_queue_push(
                    ctypes.byref(queue), ctypes.byref(header), trace % 5,
                    100 + trace, payload, 256
                ),
                OK,
            )
        ninth = Header(0, 0, 0, 256, 99, 1)
        self.assertEqual(
            self.lib.mol_tcp_request_queue_push(
                ctypes.byref(queue), ctypes.byref(ninth), 0, 999, payload, 256
            ),
            BUSY,
        )
        for trace in range(QUEUE_DEPTH):
            request = Request()
            self.assertEqual(
                self.lib.mol_tcp_request_queue_pop(
                    ctypes.byref(queue), ctypes.byref(request)
                ),
                OK,
            )
            self.assertEqual(request.header.trace_id, trace)
            self.assertEqual(request.connection_generation, 100 + trace)
        self.assertLess(
            self.lib.mol_tcp_request_queue_pop(
                ctypes.byref(queue), ctypes.byref(Request())
            ),
            0,
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
