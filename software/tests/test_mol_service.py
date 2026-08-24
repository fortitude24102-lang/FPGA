#!/usr/bin/env python3
"""Host-compile the bare-metal service supervisor with mocked hardware."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "software" / "baremetal" / "src"


HARNESS = r"""
#include "mol_service.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint64_t now;
    unsigned clock_calls;
    unsigned clock_failures;
    unsigned watchdog_kicks;
    unsigned idle_calls;
    unsigned writes;
    uint16_t temp;
    uint16_t vccint;
    uint16_t vccaux;
} mock_t;

static uint64_t timer_now(void *arg) { return ((mock_t *)arg)->now; }
static int set_clock(void *arg, uint32_t mhz) {
    mock_t *mock = (mock_t *)arg;
    (void)mhz;
    mock->clock_calls++;
    return mock->clock_calls <= mock->clock_failures ? -1 : 0;
}
static int read_xadc(void *arg, uint16_t *temp, uint16_t *vccint,
                     uint16_t *vccaux) {
    mock_t *mock = (mock_t *)arg;
    *temp = mock->temp; *vccint = mock->vccint; *vccaux = mock->vccaux;
    return 0;
}
static int write_mmio(void *arg, uintptr_t address, uint32_t value) {
    mock_t *mock = (mock_t *)arg;
    (void)address; (void)value; mock->writes++; return 0;
}
static void kick(void *arg) { ((mock_t *)arg)->watchdog_kicks++; }
static void idle(void *arg) { ((mock_t *)arg)->idle_calls++; }

static mol_service_t new_service(mock_t *mock) {
    mol_service_t service;
    mol_service_hooks_t hooks;
    memset(&hooks, 0, sizeof(hooks));
    hooks.context = mock;
    hooks.timer_now = timer_now;
    hooks.clock_set = set_clock;
    hooks.xadc_read = read_xadc;
    hooks.mmio_write = write_mmio;
    hooks.watchdog_kick = kick;
    hooks.idle = idle;
    mol_service_init(&service, &hooks, 1000000U, 0x43c00000U);
    return service;
}

int main(void) {
    mock_t mock;
    mol_service_t service;
    mol_service_snapshot_t snapshot;
    memset(&mock, 0, sizeof(mock));
    mock.temp = 45U << 8; mock.vccint = 1000; mock.vccaux = 1800;
    service = new_service(&mock);
    assert(service.state == MOL_INIT);
    assert(mol_service_mark_ready(&service) == MOL_SERVICE_OK);
    assert(service.state == MOL_READY);

    mock.clock_calls = 0; mock.clock_failures = 2;
    assert(mol_service_set_clock(&service, 150) == MOL_SERVICE_OK);
    assert(mock.clock_calls == 3 && service.clock_mhz == 150);
    assert(service.overclock_experimental == 1);
    assert(mol_service_begin(&service, 1, 2) == MOL_SERVICE_OK);
    assert(mol_service_set_clock(&service, 100) == MOL_SERVICE_ERR_BUSY);
    assert(service.state == MOL_BUSY);
    mock.now = 3999;
    mol_service_poll(&service, mock.now);
    assert(service.state == MOL_BUSY);
    mock.now = 4000;
    mol_service_poll(&service, mock.now);
    assert(service.state == MOL_READY && service.fallback_active == 1);
    assert(service.failed_count == 1);

    assert(mol_service_begin(&service, 0xfe, 1) == MOL_SERVICE_OK);
    assert(service.state == MOL_RELOAD);
    mock.now += 500;
    mol_service_complete(&service, 1, 500);
    assert(service.state == MOL_READY && service.completed_count == 1);

    mock.clock_calls = 0; mock.clock_failures = 3;
    assert(mol_service_set_clock(&service, 100) == MOL_SERVICE_ERR_IO);
    assert(service.state == MOL_ERROR && mock.clock_calls == 3);
    assert(mol_service_recover(&service) == MOL_SERVICE_OK);

    mock.now = 1000000;
    mol_service_poll(&service, mock.now);
    mol_service_snapshot(&service, &snapshot);
    assert(snapshot.temperature_q8_8 == (45U << 8));
    assert(snapshot.vccint_mv == 1000 && snapshot.vccaux_mv == 1800);
    assert(mock.writes >= 10 && mock.watchdog_kicks >= 1);

    mol_service_idle(&service);
    assert(mock.idle_calls == 1);
    mock.now = 61000000;
    mol_service_poll(&service, mock.now);
    mol_service_snapshot(&service, &snapshot);
    assert(snapshot.cpu_load_permille < 50);

    mock.temp = 81U << 8;
    mock.now += 1000000;
    mol_service_poll(&service, mock.now);
    assert(service.state == MOL_ERROR);
    puts("PASS mol_service state, timeout, retry, health and idle accounting");
    return 0;
}
"""


class MolServiceTests(unittest.TestCase):
    def test_tcp_server_integrates_supervisor(self) -> None:
        main = (SRC / "main_tcp_server.c").read_text(encoding="utf-8")
        vitis = (ROOT / "software" / "create_tcp_vitis_app.tcl").read_text(
            encoding="utf-8"
        )
        for marker in (
            '#include "mol_service.h"',
            "initialize_service_hardware",
            "mol_service_begin(&service",
            "mol_service_complete(&service",
            "mol_service_poll(&service",
            "mol_service_idle(&service)",
            "MOL_TCP_IDLE_POLL_LIMIT 5U",
        ):
            self.assertIn(marker, main)
        self.assertIn("mol_service.c mol_service.h", vitis)

    def test_host_supervisor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="mol_service_") as tmp:
            temp = pathlib.Path(tmp)
            harness = temp / "test_mol_service.c"
            executable = temp / "test_mol_service.exe"
            harness.write_text(textwrap.dedent(HARNESS), encoding="utf-8")
            subprocess.run(
                [
                    "gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    f"-I{SRC}", str(SRC / "mol_service.c"), str(harness),
                    "-o", str(executable),
                ],
                check=True,
                cwd=ROOT,
            )
            result = subprocess.run(
                [str(executable)], check=True, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            self.assertIn("PASS mol_service", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
