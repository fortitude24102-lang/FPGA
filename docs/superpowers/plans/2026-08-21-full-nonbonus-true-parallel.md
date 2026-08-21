# Full Non-Bonus True-Parallel Accelerator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete every non-bonus requirement in `FPGA修改.docx`, add DMA burst transfer and batching, run Tanimoto/GNN/ADMET as genuinely independent concurrent engines, and present board health and benchmark results on the ATK-MD0430R 800×480 RGB LCD and over TCP/HTTP.

**Architecture:** Keep the existing 128-bit AXI DMA/HP0 data plane and AXI-Lite control plane. Refactor the current accelerator backend into three independent engine lanes feeding a 64-entry sequence scoreboard, add ping-pong data banks and A/B weight banks, and preserve request-order responses even when engines complete out of order. Firmware owns health, timeouts, watchdog, dynamic clock selection, TCP/HTTP, and CPU-idle accounting. The LCD is a small procedural status renderer, not a framebuffer.

**Tech Stack:** Verilog-2001/SystemVerilog testbenches, Xilinx Vivado/Vitis 2019.2, Zynq-7015, AXI DMA 7.1, Clocking Wizard 6.0, lwIP standalone, C11-compatible bare-metal code, Python 3/unittest, Icarus Verilog.

**Spec:** `docs/superpowers/specs/2026-08-21-full-nonbonus-true-parallel-design.md`

## Global Constraints

- Work on the current `main` branch as authorized; do not create a feature branch or worktree.
- Preserve all existing user and generated-file changes. Stage only files named by the current task.
- Keep Vivado/Vitis generated products local. Commit source Tcl, RTL, C, Python, constraints, tests, documentation, and small text reports only.
- Vivado release builds must contain no ILA; debug builds may contain ILA. Do not promote a candidate build until simulation, timing, DRC, firmware build, and board acceptance all pass.
- Keep the 16-byte TCP header compatible. Protocol version 2 may add flag semantics, but must reject incompatible versions deterministically.
- Use one AXI DMA and one HP0 path. Parallelism is in the three compute engines and their buffers, not three competing DMA blocks.
- LCD touch is excluded. HDMI-IN and RGB LCD share pins and must never be enabled together.
- Explicitly excluded bonus work: multi-FPGA scaling, quantization/pruning research, and hardware-in-the-loop random-vector equivalence.

## File Responsibility Map

| Area | Source of truth | Primary tests/build checks |
|---|---|---|
| DMA/TCP contract | `protocol/mol_dma_protocol.json`, `tools/generate_dma_protocol.py` | `sim/run_tests.py`, `software/tests/test_mol_tcp_protocol.py` |
| Host client | `software/host/mol_tcp_client.py` | `software/tests/test_mol_tcp_client.py` |
| Queue/reorder | `rtl/dma_task_queue_frontend.v`, `rtl/dma_task_queue.v` | `sim/tb_dma_task_queue*.sv` |
| Compute concurrency | `rtl/dma_accelerator_backend.v`, `rtl/generator_accelerator_top.v` | `sim/tb_dma_backend_parallel.sv`, `sim/tb_pipeline_parallel.sv` |
| GNN/ADMET banks | `rtl/gnn_message_passing.v`, `rtl/fc_network.v`, `rtl/admet_predictor.v` | `sim/tb_weight_bank_switch.sv` |
| IP/Block Design | `FPGA/package_dma_accelerator_ip.tcl`, `FPGA/add_dma_batch_system.tcl` | `FPGA/check_dma_batch_bd.tcl` |
| Clock/debug/build | `FPGA/rebuild_dma_batch.tcl`, `FPGA/check_dma_reports.py` | `FPGA/test_check_dma_reports.py` |
| LCD | `rtl/lcd_status_display.v`, `constraints/Z15_LCD_800x480.xdc` | `sim/tb_lcd_status_display.sv` |
| Bare-metal service | `software/baremetal/src/mol_service.[ch]`, `software/baremetal/src/main_tcp_server.c` | host C tests and Vitis build |
| HTTP dashboard | `software/baremetal/src/mol_http_server.[ch]` | `software/tests/test_mol_http_server.py` |
| Acceptance | `software/host/run_acceptance.py`, `tools/update_acceptance_report_dma_final.py` | board UART/TCP/HTTP artifacts |

---

## Task 1: Freeze protocol v2 batch and result contract

**Files:**
- Modify: `protocol/mol_dma_protocol.json`
- Modify: `tools/generate_dma_protocol.py`
- Regenerate: `rtl/mol_dma_protocol.vh`
- Regenerate: `software/baremetal/src/mol_dma_protocol.h`
- Modify: `sim/test_protocol_generation.py`

**Interfaces:** Maximum item count is 128; maximum queued tasks is 64; transfer limit is 2 MiB. `user_tag` carries the expected IEEE CRC32 only for weight-reload tasks. `detail` returns the observed CRC32; the one-word reload result returns the active epoch. Task IDs remain `{0,1,2,3,0xFE}`.

- [ ] Add a failing generation test that asserts `MOL_DMA_MAX_ITEM_COUNT == 128`, queue depth 64, and reload CRC/epoch semantics in both generated headers.

```python
self.assertIn("`define MOL_DMA_MAX_ITEM_COUNT 128", rtl)
self.assertIn("#define MOL_DMA_MAX_ITEM_COUNT UINT32_C(128)", c_header)
self.assertEqual(spec["weight_reload"]["expected_crc_field"], "user_tag")
self.assertEqual(spec["weight_reload"]["result_epoch_words"], 1)
```

- [ ] Run `python -m unittest sim.test_protocol_generation -v` and confirm it fails because the current limit is 64 and reload metadata is absent.
- [ ] Update the JSON schema and generator validation without adding a new DMA task ID.
- [ ] Run `python tools/generate_dma_protocol.py` and inspect that both generated headers are byte-for-byte current.
- [ ] Run `python -m unittest sim.test_protocol_generation -v` and `python sim/run_tests.py protocol` and confirm both pass.
- [ ] Commit only the five named files:

```powershell
git add protocol/mol_dma_protocol.json tools/generate_dma_protocol.py rtl/mol_dma_protocol.vh software/baremetal/src/mol_dma_protocol.h sim/test_protocol_generation.py
git commit -m "feat: define v2 batched DMA protocol"
```

## Task 2: Extend TCP and host batching without changing the header size

**Files:**
- Modify: `software/baremetal/src/mol_tcp_protocol.[ch]`
- Modify: `software/host/mol_tcp_client.py`
- Modify: `software/tests/test_mol_tcp_protocol.py`
- Modify: `software/tests/test_mol_tcp_client.py`

**Interfaces:** TCP slot size is 256 KiB, FIFO depth is 8, batch sizes are Tanimoto 128, GNN 16/32, ADMET 64, Pipeline 8/16. Local service-status request ID `0xFD` is handled before DMA translation. Response flags remain `RESPONSE|BUSY|ERROR|FALLBACK`; incompatible versions return an error response and close the request cleanly.

- [ ] Add failing C/Python tests for every permitted batch boundary, slot overflow, request `0xFD`, and version rejection.

```c
int mol_tcp_dma_shape(uint8_t task_id, uint32_t batch_size,
                      uint32_t *dma_flags, uint32_t *item_count,
                      uint32_t *payload_words, uint32_t *result_words);
```

```python
for task, batches in {0:(1,128), 1:(1,16,32), 2:(1,64), 3:(1,8,16)}.items():
    for batch in batches:
        self.assertGreater(payload_words(task, batch), 0)
```

- [ ] Run `python -m unittest software.tests.test_mol_tcp_protocol software.tests.test_mol_tcp_client -v` and confirm GNN/Pipeline batch cases fail.
- [ ] Implement exact per-task word calculations with checked multiplication before allocating/copying data. Keep service status outside `mol_tcp_dma_shape()`.
- [ ] Add host constructors that concatenate items in wire order and parse one result per item.
- [ ] Run both test modules and confirm all pass.
- [ ] Commit the six named files with `git commit -m "feat: support large TCP accelerator batches"`.

## Task 3: Split the DMA backend into three independently busy engines

**Files:**
- Modify: `rtl/dma_accelerator_backend.v`
- Modify: `rtl/generator_accelerator_top.v`
- Add: `sim/tb_dma_backend_parallel.sv`
- Modify: `sim/run_tests.py`

**Interfaces:** Add `task_sequence[5:0]` at acceptance and return it with completion. Export `engine_busy[2:0]`, `engine_start[2:0]`, and `engine_done[2:0]` in Tanimoto/GNN/ADMET order. A task is accepted when its target engine ingress bank is free, even while another engine computes. A Pipeline task reserves all three lanes atomically.

- [ ] Add a failing simulation that sends Tanimoto, GNN, and ADMET without waiting between submissions and asserts overlapping busy masks and out-of-order sequence-tagged completions.

```systemverilog
submit_task(TASK_GNN, 6'd10);
submit_task(TASK_ADMET, 6'd11);
submit_task(TASK_TANIMOTO, 6'd12);
wait (&seen_busy_mask);
expect_completion(6'd12);
expect_completion(6'd11);
expect_completion(6'd10);
```

- [ ] Register test name `backend_parallel` and run `python sim/run_tests.py backend_parallel`; confirm the serial backend fails the overlap assertion.
- [ ] Replace the single monolithic backend state with three lane-local ingress/compute/result state records. Preserve the existing cores and result encoding.
- [ ] Add a one-entry completion register per lane; completion backpressure must stall only that lane.
- [ ] Run `python sim/run_tests.py backend_parallel backend_shared_overlap top` and confirm all pass.
- [ ] Commit the four named files with `git commit -m "feat: run accelerator engines independently"`.

## Task 4: Add ping-pong input banks and simultaneous Pipeline launch

**Files:**
- Modify: `rtl/generator_accelerator_top.v`
- Modify: `rtl/gnn_message_passing.v`
- Modify: `rtl/admet_predictor.v`
- Modify: `rtl/fc_network.v`
- Add: `sim/tb_pipeline_parallel.sv`
- Modify: `sim/run_tests.py`

**Interfaces:** GNN input and ADMET descriptor memories gain write-bank and run-bank selects. Pipeline launch asserts all three start pulses on the same accelerator-clock edge after its three input banks are complete. Accepted work may fill the inactive bank while the active bank computes.

- [ ] Add a failing test that records `$time` for the three start pulses, requires equality, and loads the next GNN/ADMET batch while the first Pipeline item remains busy.

```systemverilog
always @(posedge clk) begin
  if (engine_start[0]) tani_start_cycle <= cycles;
  if (engine_start[1]) gnn_start_cycle  <= cycles;
  if (engine_start[2]) admet_start_cycle <= cycles;
end
```

- [ ] Run `python sim/run_tests.py pipeline_parallel`; confirm the current serial pipeline fails.
- [ ] Widen memory addressing by one bank bit and latch the run-bank on accepted start; never swap a bank still marked busy.
- [ ] Replace `ST_PIPE_TANI -> ST_PIPE_GNN -> ST_PIPE_ADMET` with one atomic launch and a three-bit done mask.
- [ ] Run `python sim/run_tests.py pipeline_parallel pipeline_latency gnn_message_passing top` and confirm all pass.
- [ ] Commit the six named files with `git commit -m "feat: add ping-pong batched pipeline execution"`.

## Task 5: Add a 64-entry scoreboard and ordered result retirement

**Files:**
- Modify: `rtl/dma_task_queue.v`
- Modify: `rtl/dma_task_queue_frontend.v`
- Add: `sim/tb_dma_task_scoreboard.sv`
- Modify: `sim/run_tests.py`

**Interfaces:** Each entry stores valid, sequence, task ID, item count, result size, state, error/detail, and result-buffer selector. Allocate in input order; dispatch whenever the target lane has capacity; mark complete by sequence; retire only the oldest valid entry. Queue full deasserts input readiness without corrupting existing entries.

- [ ] Add a failing test that submits 64 mixed tasks, completes them in a deliberately different order, checks response order, then verifies the 65th task is backpressured until one retires.
- [ ] Run `python sim/run_tests.py task_scoreboard`; confirm the current serial queue cannot accept the burst.
- [ ] Implement 6-bit allocate/retire counters plus a 7-bit occupancy counter and sequence-matched completion update.

```verilog
wire queue_full  = (occupancy == 7'd64);
wire queue_empty = (occupancy == 7'd0);
assign retire_valid = entry_valid[retire_ptr] && entry_complete[retire_ptr];
```

- [ ] Add assertions for occupancy range, unique live sequences, no overwrite, and monotonic retirement.
- [ ] Run `python sim/run_tests.py task_scoreboard queue frontend formatter backend_parallel`; confirm all pass.
- [ ] Commit the four named files with `git commit -m "feat: reorder concurrent accelerator results"`.

## Task 6: Implement CRC-verified A/B weight reload and atomic activation

**Files:**
- Modify: `rtl/dma_accelerator_backend.v`
- Modify: `rtl/gnn_message_passing.v`
- Modify: `rtl/admet_predictor.v`
- Modify: `rtl/fc_network.v`
- Modify: `software/baremetal/src/mol_dma_queue.c`
- Add: `sim/tb_weight_bank_switch.sv`
- Modify: `sim/run_tests.py`

**Interfaces:** Reload writes only the inactive bank. IEEE CRC32 polynomial `0xEDB88320`, initial/final XOR `0xFFFFFFFF`, is calculated over payload bytes in wire order. Matching CRC atomically flips active bank and increments a 32-bit epoch; mismatch keeps the active bank unchanged and returns an error with observed CRC in `detail`.

- [ ] Add a failing test for successful reload during active inference and a corrupted reload. Verify the active inference uses old weights, the next inference uses new weights, and corrupted data never changes epoch/bank.
- [ ] Run `python sim/run_tests.py weight_bank_switch`; confirm bank/CRC behavior is absent.
- [ ] Add `cfg_bank` and `run_bank` to GNN and all four FC networks; latch run-bank at start.
- [ ] Implement byte-wise CRC accumulation as each 128-bit payload beat is accepted and compare against `user_tag` after the final byte.

```c
int mol_dma_reload_weights(mol_dma_context_t *ctx, const uint32_t *words,
                           uint32_t word_count, uint32_t expected_crc,
                           uint32_t *new_epoch, uint32_t *observed_crc);
```

- [ ] Run `python sim/run_tests.py weight_bank_switch weight_reload backend_parallel` and the bare-metal host compile tests.
- [ ] Commit the seven named files with `git commit -m "feat: atomically reload verified weight banks"`.

## Task 7: Add controlled 50/100/150 MHz operation, debug probes, and build gates

**Files:**
- Modify: `FPGA/add_dma_batch_system.tcl`
- Modify: `FPGA/check_dma_batch_bd.tcl`
- Modify: `FPGA/package_dma_accelerator_ip.tcl`
- Modify: `FPGA/rebuild_dma_batch.tcl`
- Modify: `FPGA/check_dma_reports.py`
- Modify: `FPGA/test_check_dma_reports.py`

**Interfaces:** AXI control remains 100 MHz, DMA remains 125 MHz, LCD is 33 MHz, and the accelerator Clocking Wizard exposes runtime-selectable 50/100/150 MHz profiles over AXI-Lite. Clock changes are permitted only while service state is READY and all engine-busy bits are zero. Debug build probes queue occupancy, lane start/busy/done, sequence, clock profile, service state, and error detail.

- [ ] Add failing Python/Tcl checks requiring all five clocks, Clocking Wizard AXI mapping at `0x80410000`, synchronized resets, debug ILA probes, and no ILA in release artifacts.
- [ ] Run `python -m unittest FPGA.test_check_dma_reports -v` and the BD checker; confirm missing clock/profile checks fail.
- [ ] Configure Clocking Wizard 6.0 with `USE_DYN_RECONFIG=true`, `INTERFACE_SELECTION=Enable_AXI`, 100 MHz input, and validated 50/100/150 MHz profiles. Connect its locked output into `proc_sys_reset` and use the output only on accelerator-side async FIFO/core clocks.
- [ ] Extend the build Tcl to create candidate debug/release products, run implementation, require routed status and DRC clean, and record WNS/TNS plus LUT/FF/BRAM/DSP use for each profile.
- [ ] Run `vivado.bat -mode batch -source FPGA/check_dma_batch_bd.tcl` and `python -m unittest FPGA.test_check_dma_reports -v`.
- [ ] Commit the six named files with `git commit -m "feat: gate multi-frequency debug and release builds"`.

## Task 8: Drive the ATK-MD0430R 800×480 RGB LCD

**Files:**
- Add: `rtl/lcd_status_display.v`
- Add: `sim/tb_lcd_status_display.sv`
- Add: `constraints/Z15_LCD_800x480.xdc`
- Modify: `FPGA/package_dma_accelerator_ip.tcl`
- Modify: `FPGA/add_dma_batch_system.tcl`
- Modify: `sim/run_tests.py`

**Interfaces:** 33 MHz pixel clock; horizontal `48 sync + 88 back + 800 active + 40 front = 976`; vertical `3 sync + 32 back + 480 active + 13 front = 528`. Outputs are RGB888, HSYNC, VSYNC, DE, pixel clock, reset, and backlight. The fixed dashboard shows service state, clock, temperatures/voltages, lane activity, completed/failed counts, and latest four latency/speedup values.

- [ ] Add a failing timing test that counts exact sync, porch, active, frame lengths; also require reset low and backlight off until clock lock plus 20 ms.
- [ ] Run `python sim/run_tests.py lcd_status`; confirm the module is missing.
- [ ] Implement counters, a compact 8×16 glyph ROM, fixed labels, decimal/hex renderers, and status-value snapshotting at frame start.

```verilog
localparam H_SYNC=48, H_BACK=88, H_ACTIVE=800, H_FRONT=40;
localparam V_SYNC=3,  V_BACK=32, V_ACTIVE=480, V_FRONT=13;
```

- [ ] Constrain every LCD signal from the Z15 pin sheet at LVCMOS33; add a design note in the XDC that HDMI-IN must remain disabled while LCD pins are active.
- [ ] Add LCD RTL to IP packaging and make ports external in the BD Tcl.
- [ ] Run `python sim/run_tests.py lcd_status` plus `vivado.bat -mode batch -source FPGA/check_dma_batch_bd.tcl`.
- [ ] Commit the six named files with `git commit -m "feat: add 800x480 board status display"`.

## Task 9: Add the bare-metal service state machine, health, watchdog, DFS, and CPU accounting

**Files:**
- Add: `software/baremetal/src/mol_service.h`
- Add: `software/baremetal/src/mol_service.c`
- Modify: `software/baremetal/src/main_tcp_server.c`
- Modify: `software/create_tcp_vitis_app.tcl`
- Add: `software/tests/test_mol_service.py`

**Interfaces:** States are `INIT, READY, BUSY, RELOAD, ERROR`. AXI transactions retry 3 times with 100 µs timeout; PL job timeout is `2 ms × item_count` then FALLBACK; TCP request timeout is 5 s; PS watchdog is 10 s. XADC reports internal temperature, VCCINT, and VCCAUX. Idle processing executes `wfi`; CPU load is busy cycles divided by elapsed global-timer cycles and must remain below 5% during an idle 60 s interval.

- [ ] Add a host-compiled test using mocked MMIO/timer/XADC/watchdog hooks that drives every state transition, timeout, retry, clock rejection while busy, and CPU calculation.

```c
typedef enum { MOL_INIT, MOL_READY, MOL_BUSY, MOL_RELOAD, MOL_ERROR } mol_service_state_t;
int mol_service_set_clock(mol_service_t *service, uint32_t mhz);
int mol_service_begin(mol_service_t *service, uint8_t task_id, uint32_t items);
void mol_service_poll(mol_service_t *service, uint64_t now_ticks);
```

- [ ] Run `python -m unittest software.tests.test_mol_service -v`; confirm the new API is absent.
- [ ] Implement the service module with dependency-injected hooks for host tests and BSP-backed hooks for `XAdcPs`, `XScuWdt`, global timer, and Clocking Wizard MMIO.
- [ ] Refactor `main_tcp_server.c` to delegate state/health/timeouts and call `mol_service_idle()` only when no TCP or DMA work is pending.
- [ ] Add both files to `app_sources` and run `xsct.bat software/create_tcp_vitis_app.tcl`.
- [ ] Run the unit test and a clean Vitis build; confirm zero compiler warnings from the new files.
- [ ] Commit the five named files with `git commit -m "feat: supervise accelerator health and clocks"`.

## Task 10: Serve the on-board HTTP dashboard and JSON health APIs

**Files:**
- Add: `software/baremetal/src/mol_http_server.h`
- Add: `software/baremetal/src/mol_http_server.c`
- Modify: `software/baremetal/src/main_tcp_server.c`
- Modify: `software/create_tcp_vitis_app.tcl`
- Add: `software/tests/test_mol_http_server.py`

**Interfaces:** TCP port 5001 remains the binary accelerator service. HTTP port 80 serves `/`, `/api/fpga/health`, and `/api/fpga/benchmark`. Responses are bounded, static-buffer generated, valid HTTP/1.0, and include `Content-Length` and `Connection: close`. Unknown paths return 404; non-GET methods return 405.

- [ ] Add a host-compiled test that feeds fragmented requests and validates status line, content length, JSON keys, and buffer bounds.
- [ ] Run `python -m unittest software.tests.test_mol_http_server -v`; confirm the server module is absent.
- [ ] Implement a single fixed HTML page that polls both JSON routes once per second; do not add a filesystem, template engine, or JavaScript dependency.

```c
int mol_http_respond(const char *request, size_t request_len,
                     const mol_service_snapshot_t *health,
                     const mol_benchmark_snapshot_t *bench,
                     char *response, size_t capacity, size_t *response_len);
```

- [ ] Integrate a dedicated lwIP listener on port 80 without blocking the binary service.
- [ ] Run the HTTP unit test and Vitis build.
- [ ] Commit the five named files with `git commit -m "feat: expose board health dashboard"`.

## Task 11: Add concurrency, fallback, performance, and endurance acceptance tools

**Files:**
- Add: `software/host/run_acceptance.py`
- Modify: `software/host/mol_tcp_client.py`
- Add: `software/tests/test_run_acceptance.py`
- Modify: `software/host/README.md`

**Interfaces:** Acceptance runs 5 concurrent clients, 1000 Pipeline samples with jitter at most ±5 µs, and 100,000 Tanimoto molecules within 5 minutes. It tests batch sets from Task 2 at 50/100/150 MHz, records hardware and software fallback outputs, and compares exact fixed-point results against software references. Exit code is nonzero if any target fails.

- [ ] Add deterministic fake-server tests covering concurrent request correlation, timeout/fallback, percentile/jitter calculations, and JSON result schema.
- [ ] Run `python -m unittest software.tests.test_run_acceptance -v`; confirm the runner is missing.
- [ ] Implement one worker per client using only Python standard-library `socket`, `threading`, `statistics`, and `json`; make the random seed and target address explicit command-line arguments.

```python
TARGETS = {
    "clients": 5, "pipeline_samples": 1000,
    "pipeline_jitter_us": 5.0,
    "tanimoto_molecules": 100000, "tanimoto_deadline_s": 300.0,
}
```

- [ ] Emit `reports/acceptance/latest.json` and a concise console table containing pass/fail, throughput, latency, jitter, CPU load, clock, XADC values, and fallback count.
- [ ] Run the unit test and `python -m compileall software/host`.
- [ ] Commit the four named files with `git commit -m "test: automate concurrent board acceptance"`.

## Task 12: Run complete regression, build, board validation, and promote artifacts

**Files:**
- Modify: `tools/update_acceptance_report_dma_final.py`
- Create from tool: `reports/verification_report.md`
- Create locally, do not commit: `reports/acceptance/latest.json`, debug/release bitstreams, XSA, ELF, ILA captures, UART logs
- Modify if needed: only source/test files whose failing check exposes a defect

**Interfaces:** Promotion is all-or-nothing. Required evidence includes protocol/software/RTL tests, clean release DRC, positive WNS at 50/100/150 MHz, correct LCD, three-lane ILA overlap, HTTP health, five clients, CPU below 5%, 1000-sample Pipeline jitter, 100k Tanimoto endurance, and exact result checks. Report speedups separately for Tanimoto, GNN, ADMET, and Pipeline.

- [ ] Run the complete deterministic suite:

```powershell
python -m unittest discover -s software/tests -v
python -m unittest discover -s FPGA -p "test_*.py" -v
python sim/run_tests.py all
python tools/generate_dma_protocol.py --check
```

- [ ] Run the candidate Vivado flow and reject it unless implementation is routed, DRC is clean, WNS is positive for all three accelerator profiles, and the release design contains no ILA.
- [ ] Build the Vitis TCP/HTTP application from the new XSA, program the board after power-cycle, and capture UART startup plus LCD photographs.
- [ ] Capture an ILA trace where all three `engine_busy` bits are high and the three Pipeline `engine_start` bits rise on one accelerator-clock edge.
- [ ] Set `$env:MOL_BOARD_IP` to the board address printed by UART, then run `python software/host/run_acceptance.py --host $env:MOL_BOARD_IP --port 5001 --http-port 80 --seed 7015`.
- [ ] Run `python tools/update_acceptance_report_dma_final.py` and verify the report links every artifact, contains no unsupported claim, and distinguishes measured results from targets.
- [ ] Stage only the report generator and text verification report, then commit:

```powershell
git add tools/update_acceptance_report_dma_final.py reports/verification_report.md
git commit -m "docs: record full accelerator acceptance"
```

- [ ] Confirm `git status --short` contains only the pre-existing Vivado/Vitis generated changes and any intentionally uncommitted binary/log artifacts. Do not push until the user explicitly requests it.

## Final Acceptance Matrix

| Requirement | Evidence |
|---|---|
| DMA, HP0 burst, batch processing | BD checker, protocol tests, batch acceptance JSON |
| True Tanimoto/GNN/ADMET concurrency | RTL overlap test and ILA three-bit busy trace |
| True Pipeline simultaneous start | same-cycle RTL assertion and ILA start trace |
| Out-of-order completion with ordered replies | 64-entry scoreboard simulation |
| Safe online weight update | CRC corruption test, epoch/bank switch simulation |
| 50/100/150 MHz operation | positive-WNS reports and board clock-profile runs |
| Robust service | retry/timeout/fallback/watchdog tests and UART log |
| CPU below 5% | 60-second service telemetry record |
| TCP/HTTP integration | five-client run and all three HTTP routes |
| 800×480 LCD | exact timing simulation and board photograph |
| Performance/endurance | 1000 Pipeline samples and 100k Tanimoto run |
| Reproducible release | clean tests, DRC, XSA/ELF/bitstream hashes in report |
