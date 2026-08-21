import socket
import struct
import sys
import tempfile
import unittest
from pathlib import Path


HOST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(HOST_DIR))

import mol_tcp_client as client


class MolTcpClientTests(unittest.TestCase):
    def test_recv_exact_reassembles_split_header_and_payload(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        payload = struct.pack("<4I", 1, 2, 3, 4)
        frame = client.pack_header(
            client.TASK_ADMET, client.FLAG_RESPONSE, len(payload), 77, 1
        ) + payload

        for chunk in (frame[:1], frame[1:4], frame[4:16], frame[16:19], frame[19:]):
            right.sendall(chunk)

        response = client.receive_response(left, client.TASK_ADMET, 77, 1)
        self.assertEqual(response.payload, payload)
        self.assertEqual(response.words, (1, 2, 3, 4))

    def test_busy_and_error_flags_raise_server_error(self):
        for flags in (
            client.FLAG_RESPONSE | client.FLAG_BUSY | client.FLAG_ERROR,
            client.FLAG_RESPONSE | client.FLAG_ERROR,
        ):
            with self.subTest(flags=flags):
                left, right = socket.socketpair()
                try:
                    error_payload = struct.pack("<II", 5, 8)
                    right.sendall(
                        client.pack_header(
                            client.TASK_GNN, flags, len(error_payload), 9, 1
                        )
                        + error_payload
                    )
                    with self.assertRaises(client.ServerError) as raised:
                        client.receive_response(left, client.TASK_GNN, 9, 1)
                    self.assertEqual(raised.exception.code, 5)
                    self.assertEqual(raised.exception.detail, 8)
                    self.assertEqual(raised.exception.busy, bool(flags & client.FLAG_BUSY))
                finally:
                    left.close()
                    right.close()

    def test_mismatched_trace_id_is_rejected(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        right.sendall(
            client.pack_header(
                client.TASK_TANIMOTO, client.FLAG_RESPONSE, 4, 101, 1
            )
            + struct.pack("<I", 0x10000)
        )

        with self.assertRaisesRegex(client.ProtocolError, "trace"):
            client.receive_response(left, client.TASK_TANIMOTO, 100, 1)

    def test_unsolicited_busy_response_preserves_its_trace(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        error_payload = struct.pack("<II", 5, 8)
        right.sendall(
            client.pack_header(
                client.TASK_TANIMOTO,
                client.FLAG_RESPONSE | client.FLAG_BUSY | client.FLAG_ERROR,
                len(error_payload), 7108, 1,
            )
            + error_payload
        )

        with self.assertRaises(client.ServerError) as raised:
            client.receive_response(left, client.TASK_TANIMOTO, None, 1)
        self.assertEqual(raised.exception.trace_id, 7108)

    def test_reserved_and_inconsistent_response_flags_are_rejected(self):
        for flags in (
            client.FLAG_RESPONSE | 0x80,
            client.FLAG_RESPONSE | client.FLAG_BUSY,
        ):
            with self.subTest(flags=flags):
                left, right = socket.socketpair()
                try:
                    right.sendall(
                        client.HEADER.pack(
                            client.MAGIC, client.VERSION,
                            client.TASK_TANIMOTO, flags, 4, 14, 1,
                        )
                        + struct.pack("<I", 0x10000)
                    )
                    with self.assertRaisesRegex(client.ProtocolError, "flags"):
                        client.receive_response(
                            left, client.TASK_TANIMOTO, 14, 1
                        )
                finally:
                    left.close()
                    right.close()

    def test_fallback_response_flag_is_accepted(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        right.sendall(
            client.pack_header(
                client.TASK_TANIMOTO,
                client.FLAG_RESPONSE | client.FLAG_FALLBACK,
                4, 16, 1,
            )
            + struct.pack("<I", 0x10000)
        )

        response = client.receive_response(
            left, client.TASK_TANIMOTO, 16, 1
        )
        self.assertEqual(response.words, (0x10000,))

    def test_mismatched_batch_size_is_rejected(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)
        right.sendall(
            client.pack_header(
                client.TASK_ADMET, client.FLAG_RESPONSE, 4, 15, 2
            )
            + struct.pack("<I", 0xBB)
        )

        with self.assertRaisesRegex(client.ProtocolError, "batch"):
            client.receive_response(left, client.TASK_ADMET, 15, 1)

    def test_payload_shape_is_checked_before_connect(self):
        with self.assertRaisesRegex(ValueError, "payload"):
            client.request(
                "192.0.2.1", client.TASK_TANIMOTO, b"bad", 1, 1, timeout=0.01
            )

    def test_pack_weights_has_exact_size_and_model_order(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "weights.bin"
            client.pack_weights(output)
            packed = output.read_bytes()
        data_dir = HOST_DIR.parents[1] / "test_data"
        first_gnn = int(
            (data_dir / "gnn_weights_q8_8.mem").read_text().splitlines()[0], 16
        )
        first_admet = int(
            (data_dir / "admet_0_hidden_weights.mem").read_text().splitlines()[0],
            16,
        )
        self.assertEqual(len(packed), 18152)
        self.assertEqual(struct.unpack_from("<H", packed, 0)[0], first_gnn)
        self.assertEqual(struct.unpack_from("<H", packed, 8192 * 2)[0], first_admet)

    def test_pack_weights_rejects_wrong_source_count(self):
        with tempfile.TemporaryDirectory() as directory:
            data_dir = Path(directory)
            (data_dir / "gnn_weights_q8_8.mem").write_text("0000\n")
            with self.assertRaisesRegex(ValueError, "expected 8192"):
                client.pack_weights(data_dir / "weights.bin", data_dir)

    def test_selftest_weight_image_matches_startup_layout(self):
        packed = (HOST_DIR.parents[1] / "test_data" / "selftest_weights.bin").read_bytes()
        halfwords = struct.unpack("<9076H", packed)
        expected = {0}
        for model in range(4):
            base = 8192 + model * 221
            expected.update((base, base + 210))
        self.assertEqual({i for i, value in enumerate(halfwords) if value}, expected)
        self.assertTrue(all(halfwords[i] == 0x100 for i in expected))


if __name__ == "__main__":
    unittest.main(verbosity=2)
