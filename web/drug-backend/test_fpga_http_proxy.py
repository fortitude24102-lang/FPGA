import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from agents.fpga_client import FPGAClient


HEALTH = {
    "status": "READY",
    "online": True,
    "fault": False,
    "current_task": "Idle",
    "completed_tasks": 7,
    "failed_tasks": 1,
    "avg_latency_us": 30,
    "temperature_c": 46.84,
    "batch_completed": 0,
    "batch_total": 0,
}

BENCHMARK = {
    "lanes": [
        {"name": "Tanimoto", "cpu_us": 384, "fpga_us": 33, "speedup": 120.0},
        {"name": "GNN", "cpu_us": 26942, "fpga_us": 797, "speedup": 33.8},
    ]
}


class BoardHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = {
            "/api/fpga/health": HEALTH,
            "/api/fpga/benchmark": BENCHMARK,
        }.get(self.path)
        if payload is None:
            self.send_error(404)
            return
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class FPGAHttpProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), BoardHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.board_url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_reads_real_health_and_maps_existing_status_contract(self):
        client = FPGAClient(service_url=self.board_url, enabled=True, timeout=1)

        self.assertTrue(client.connect())
        self.assertEqual(client.get_health(), HEALTH)
        status = client.get_status()
        self.assertTrue(status["connected"])
        self.assertTrue(status["enabled"])
        self.assertEqual(status["service_url"], self.board_url)
        self.assertEqual(status["completed_tasks"], 7)
        self.assertEqual(status["failed_tasks"], 1)
        self.assertEqual(status["temperature_c"], 46.84)

    def test_reads_benchmark_and_preserves_existing_performance_contract(self):
        client = FPGAClient(service_url=self.board_url, enabled=True, timeout=1)

        self.assertEqual(client.get_benchmark(), BENCHMARK)
        report = client.get_performance_report()
        self.assertTrue(report["fpga_connected"])
        self.assertEqual(report["lanes"], BENCHMARK["lanes"])
        self.assertEqual(report["total_requests"], 7)
        self.assertEqual(report["total_errors"], 1)
        self.assertEqual(report["avg_compute_time_ms"], 0.03)


if __name__ == "__main__":
    unittest.main()
