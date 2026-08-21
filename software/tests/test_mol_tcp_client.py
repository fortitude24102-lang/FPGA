#!/usr/bin/env python3
"""Host tests for batched TCP accelerator payloads and results."""

import pathlib
import struct
import sys
import unittest


HOST_DIR = pathlib.Path(__file__).resolve().parents[1] / "host"
sys.path.insert(0, str(HOST_DIR))

import mol_tcp_client as client


class MolTcpClientBatchTests(unittest.TestCase):
    def test_permitted_batch_boundaries_have_payloads(self):
        for task, batches in {0: (1, 128), 1: (1, 16, 32),
                              2: (1, 64), 3: (1, 8, 16)}.items():
            for batch in batches:
                with self.subTest(task=task, batch=batch):
                    self.assertGreater(client.payload_words(task, batch), 0)

    def test_batch_constructors_preserve_item_wire_order(self):
        gnn = client.gnn_payload(2)
        self.assertEqual(struct.unpack_from("<I", gnn, 0)[0], 1)
        self.assertEqual(struct.unpack_from("<I", gnn, 1679 * 4)[0], 2)
        admet = client.admet_payload([3, 4])
        self.assertEqual(struct.unpack("<40I", admet)[::20], (3, 4))
        pipeline = client.pipeline_payload(2)
        self.assertEqual(struct.unpack_from("<I", pipeline, 0)[0], 0xFFFFFFFF)
        self.assertEqual(struct.unpack_from("<I", pipeline, 1763 * 4)[0], 0xFFFFFFFF)

    def test_result_splitter_returns_one_tuple_per_item(self):
        self.assertEqual(client.split_results(0, (7, 8), 2), ((7,), (8,)))
        self.assertEqual(client.split_results(2, tuple(range(8)), 2),
                         ((0, 1, 2, 3), (4, 5, 6, 7)))
        self.assertEqual(client.split_results(0xFE, (9,), 1), ((9,),))

    def test_incompatible_response_version_is_rejected(self):
        class Connection:
            def recv(self, size):
                return struct.pack("<BBBBIII", client.MAGIC, 2,
                                   client.TASK_GNN, client.FLAG_RESPONSE,
                                   0, 1, 1)

        with self.assertRaisesRegex(client.ProtocolError, "version"):
            client.receive_response(Connection(), client.TASK_GNN, 1, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
