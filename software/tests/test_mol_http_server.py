#!/usr/bin/env python3
"""Host tests for the bounded bare-metal HTTP dashboard responder."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "software" / "baremetal" / "src"


HARNESS = r"""
#include "mol_http_server.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void expect_response(const char *request, const char *status,
                            const char *needle,
                            const mol_service_snapshot_t *health,
                            const mol_benchmark_snapshot_t *benchmark) {
    char response[MOL_HTTP_MAX_RESPONSE];
    size_t response_len = 0U;
    int rc = mol_http_respond(request, strlen(request), health, benchmark,
                              response, sizeof(response), &response_len);
    assert(rc == MOL_HTTP_READY);
    assert(response_len > 0U && response_len < sizeof(response));
    response[response_len] = '\0';
    assert(strstr(response, status) != NULL);
    assert(strstr(response, "Content-Length:") != NULL);
    assert(strstr(response, "Connection: close") != NULL);
    assert(strstr(response, needle) != NULL);
}

int main(void) {
    mol_service_snapshot_t health;
    mol_benchmark_snapshot_t benchmark;
    char response[MOL_HTTP_MAX_RESPONSE];
    size_t response_len = 123U;
    unsigned lane;

    memset(&health, 0, sizeof(health));
    memset(&benchmark, 0, sizeof(benchmark));
    health.online = 1U;
    health.state = MOL_BUSY;
    health.current_task = 1U;
    health.completed_count = 42U;
    health.failed_count = 2U;
    health.avg_latency_us = 5890U;
    health.temperature_q8_8 = (45U << 8) | 128U;
    health.vccint_mv = 1000U;
    health.vccaux_mv = 1800U;
    health.clock_mhz = 150U;
    health.cpu_load_permille = 375U;
    health.fallback_active = 1U;
    health.overclock_experimental = 1U;
    health.batch_completed = 25000U;
    health.batch_total = 100000U;
    for (lane = 0U; lane < 4U; ++lane) {
        benchmark.cpu_latency_us[lane] = 100U + lane;
        benchmark.latest_latency_us[lane] = 10U + lane;
        benchmark.speedup_q8_8[lane] = (uint16_t)((10U + lane) << 8);
    }

    assert(mol_http_respond("GET /api/fpga/health HTTP/1.1\r\nHost: z15\r\n",
                            strlen("GET /api/fpga/health HTTP/1.1\r\nHost: z15\r\n"),
                            &health, &benchmark, response, sizeof(response),
                            &response_len) == MOL_HTTP_INCOMPLETE);
    assert(response_len == 0U);

    expect_response("GET /api/fpga/health HTTP/1.1\r\nHost: z15\r\n\r\n",
                    "200 OK", "\"progress_percent\":25", &health,
                    &benchmark);
    expect_response("GET /api/fpga/health HTTP/1.0\r\n\r\n",
                    "200 OK", "\"temperature_c\":45.50", &health,
                    &benchmark);
    expect_response("GET /api/fpga/benchmark HTTP/1.1\r\n\r\n",
                    "200 OK", "\"name\":\"Pipeline\"", &health,
                    &benchmark);
    expect_response("GET / HTTP/1.1\r\n\r\n", "200 OK",
                    "setInterval(refresh,2000)", &health, &benchmark);
    expect_response("GET /missing HTTP/1.1\r\n\r\n", "404 Not Found",
                    "Not Found", &health, &benchmark);
    expect_response("POST /api/fpga/health HTTP/1.1\r\n\r\n",
                    "405 Method Not Allowed", "Method Not Allowed", &health,
                    &benchmark);

    assert(mol_http_respond("GET / HTTP/1.1\r\n\r\n", 18U, &health,
                            &benchmark, response, 32U, &response_len) ==
           MOL_HTTP_ERR_CAPACITY);
    puts("PASS mol_http routes, JSON, dashboard and bounded responses");
    return 0;
}
"""


class MolHttpServerTests(unittest.TestCase):
    def test_host_http_responder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mol_http_") as tmp:
            temp = pathlib.Path(tmp)
            harness = temp / "test_mol_http.c"
            executable = temp / "test_mol_http.exe"
            harness.write_text(textwrap.dedent(HARNESS), encoding="utf-8")
            subprocess.run(
                [
                    "gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    f"-I{SRC}", str(SRC / "mol_http_server.c"), str(harness),
                    "-o", str(executable),
                ],
                check=True,
                cwd=ROOT,
            )
            result = subprocess.run(
                [str(executable)], check=True, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            self.assertIn("PASS mol_http", result.stdout)

    def test_tcp_service_exposes_both_ports(self) -> None:
        main = (SRC / "main_tcp_server.c").read_text(encoding="utf-8")
        vitis = (ROOT / "software" / "create_tcp_vitis_app.tcl").read_text(
            encoding="utf-8"
        )
        self.assertIn('#include "mol_http_server.h"', main)
        self.assertIn("MOL_HTTP_PORT 80U", main)
        self.assertIn("mol_http_respond", main)
        self.assertIn("mol_http_server.c mol_http_server.h", vitis)


if __name__ == "__main__":
    unittest.main(verbosity=2)
