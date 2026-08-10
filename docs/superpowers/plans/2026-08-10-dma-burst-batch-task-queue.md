# MolRecommender DMA Burst Batch Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a backward-compatible AXI DMA data plane and a 64-entry mixed task queue for Tanimoto, GNN, ADMET, and Pipeline jobs, then prove correctness, timing closure, transfer bandwidth, and end-to-end acceleration on the Z15 board.

**Architecture:** Keep the validated GP0 AXI-Lite register path and all existing compute cores. Add a 128-bit AXI-Stream queue endpoint to the accelerator IP, connect it through input/output AXIS FIFOs to an AXI DMA in Simple Mode, and connect the DMA memory masters to PS HP0 at 150 MHz. Software builds one contiguous `MOLQ` request, starts S2MM before MM2S, then parses `MOLR` records and the final `MOLE` trailer. A single scheduler arbitrates legacy and DMA ownership of the existing compute cores.

**Tech Stack:** Verilog-2001/SystemVerilog, Icarus Verilog, Python 3/unittest, Vivado 2019.2 Tcl, Zynq-7000 PS, AXI DMA, AXIS Data FIFO, AXI SmartConnect, Vitis 2019.2 standalone C, XAxiDma, Xilinx cache APIs.

## Global Constraints

- Work in the existing dirty tree; preserve all validated uncommitted RTL and never reset unrelated user changes.
- Stage only files named by the current task. Do not use `git add -A`.
- Keep the legacy accelerator register base at `0x43C00000` and keep the existing nine RTL regressions passing.
- Do not add DSP blocks: final accelerator-plus-DMA design must remain at or below 80 DSP48s.
- The promoted production build must not contain the large AXI System ILA.
- Do not overwrite stable `.bit`, `.xsa`, or Vitis applications until the candidate passes regression, implementation, and board tests.
- Treat the protocol JSON as the single source of truth. Generated Verilog and C constants must never be edited by hand.
- Run all tests from `D:\FPGA` unless a step gives a different working directory.
- For every RTL handshake, hold payload, `TKEEP`, and `TLAST` stable while `TVALID=1 && TREADY=0`.

## File and Responsibility Map

| Path | Responsibility |
|---|---|
| `protocol/mol_dma_protocol.json` | Canonical magic values, field offsets, flags, status codes, and size limits |
| `tools/generate_dma_protocol.py` | Deterministic Verilog/C constant generator and `--check` drift detector |
| `rtl/mol_dma_protocol.vh` | Generated RTL constants |
| `software/baremetal/src/mol_dma_protocol.h` | Generated software constants |
| `rtl/dma_task_queue_frontend.v` | AXIS word unpacking, batch/task header validation, payload dispatch |
| `rtl/tanimoto_stream_batch.v` | Shared-query task-0 execution and ordered Q16.16 results |
| `rtl/dma_task_queue.v` | Payload loading, scheduler, timeout/error policy, core ownership |
| `rtl/dma_result_formatter.v` | `MOLR`/record/`MOLE` serialization and AXIS backpressure |
| `rtl/generator_accelerator_top.v` | Legacy/DMA arbitration and top-level 128-bit AXIS ports |
| `sim/tb_dma_*.sv`, `sim/tb_tanimoto_stream_batch.sv` | Module-level failure-first RTL tests |
| `sim/tb_top_dma.sv` | Mixed batch integration and legacy compatibility tests |
| `sim/run_tests.py` | Unified protocol and RTL regression runner |
| `FPGA/package_dma_accelerator_ip.tcl` | Repeatable IP source sync and AXIS interface packaging |
| `FPGA/add_dma_batch_system.tcl` | Repeatable PS/HP0/DMA/FIFO/reset/interrupt BD construction |
| `software/baremetal/src/mol_dma_queue.[ch]` | Packet builder, DMA lifecycle, cache maintenance, result parser |
| `software/baremetal/src/main_dma_batch.c` | Board functional, stress, error, bandwidth, and speed tests |
| `software/tests/test_mol_dma_layout.py` | Host-side golden-vector and bounds tests for C-visible layout |
| `software/create_dma_vitis_app.tcl` | Reproducible standalone DMA application creation |
| `FPGA/rebuild_dma_batch.tcl` | Candidate synthesis, implementation, timing/DRC gates, artifact export |
| `reports/dma_batch/` | Machine-readable and human-readable verification evidence |

---

### Task 1: Establish one protocol source and drift checks

**Files:**
- Create: `protocol/mol_dma_protocol.json`
- Create: `tools/generate_dma_protocol.py`
- Create: `sim/test_dma_protocol_codegen.py`
- Generate: `rtl/mol_dma_protocol.vh`
- Generate: `software/baremetal/src/mol_dma_protocol.h`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Consumes: approved `MOLQ`/`MOLR`/`MOLE` word layout from the design spec.
- Produces: identical integer constants for Verilog and C, plus a non-writing `--check` command.

- [ ] Add a failing Python test that imports the generator, loads the JSON, and asserts the exact magic values, version, eight-word header sizes, maximum 64 tasks, 2 MiB transfer limit, flags, and all status codes.

```python
self.assertEqual(spec["magic"]["request"], 0x4D4F4C51)
self.assertEqual(spec["magic"]["response"], 0x4D4F4C52)
self.assertEqual(spec["magic"]["trailer"], 0x4D4F4C45)
self.assertEqual(spec["limits"]["max_tasks"], 64)
self.assertEqual(spec["headers"]["task_words"], 8)
```

- [ ] Run `python sim/test_dma_protocol_codegen.py` and verify it fails because the source/generator does not exist.
- [ ] Create JSON entries for task IDs 0..3, flag bit positions 8..10, status values 0..11, payload constants, and header field word offsets.
- [ ] Implement deterministic generation with uppercase guards and a stable sorted order. The CLI contract is:

```powershell
python tools/generate_dma_protocol.py
python tools/generate_dma_protocol.py --check
```

- [ ] Generate `rtl/mol_dma_protocol.vh` with `` `define MOL_DMA_*`` constants and `mol_dma_protocol.h` with `#define MOL_DMA_*` constants plus packed eight-word header structs guarded by static size assertions.
- [ ] Add the protocol unit test and generator `--check` to `sim/run_tests.py`; a generated-file mismatch must make the regression exit nonzero.
- [ ] Run `python sim/test_dma_protocol_codegen.py` and `python sim/run_tests.py`; verify the protocol test and all existing nine RTL tests pass.
- [ ] Commit only the six Task 1 files with `git commit -m "feat: define DMA batch wire protocol"`.

---

### Task 2: Parse and validate 128-bit input batches

**Files:**
- Create: `rtl/dma_task_queue_frontend.v`
- Create: `sim/tb_dma_task_queue_frontend.sv`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Consumes: `s_axis_job_tdata[127:0]`, `tkeep[15:0]`, `tvalid`, `tlast` with ready/valid backpressure.
- Produces: one-cycle `batch_valid`, `task_valid`, and `payload_valid` events held by corresponding ready inputs; normalized 32-bit fields; final `batch_end`; protocol error status/detail.

- [ ] Write a failing testbench that sends a one-task Tanimoto request, stalls command/payload consumers, and checks all fields and 64 payload words in exact order.
- [ ] Add cases for 1/2/3/4 valid words in the final beat and randomized source bubbles plus sink backpressure.
- [ ] Add negative cases for bad magic/version, task count 0/65, reserved bits, unknown task/flag, invalid item count, payload length mismatch, early `TLAST`, late `TLAST`, and non-contiguous/non-final partial `TKEEP`.
- [ ] Run only the new test through `python sim/run_tests.py --test dma_frontend`; verify compile failure identifies the missing module.
- [ ] Implement a four-lane word sequencer. A beat is accepted only on `s_axis_job_tvalid && s_axis_job_tready`; preserve the beat until all valid lanes have been emitted.
- [ ] Implement explicit states `BATCH_HEADER`, `TASK_HEADER`, `PAYLOAD`, `DRAIN_TO_TLAST`, and `BATCH_DONE`, and 32-bit counters for observed/declared words.
- [ ] Validate task payload shapes exactly:

```verilog
task 0 pair:         flags.SHARED_QUERY == 0, item_count == 1, payload_words == 64
task 0 shared:       flags.SHARED_QUERY == 1, payload_words == 32 + 32*item_count
task 1:              item_count == 1, payload_words == 1679
task 2:              payload_words == 20*item_count
task 3:              item_count == 1, payload_words == 1763
```

- [ ] On a task error, emit its header and error once, then consume exactly `payload_words`; continue only when batch flag bit 0 is set. On a batch error, drain through `TLAST` and emit one batch error.
- [ ] Run the focused test five times with different random seeds, then run `python sim/run_tests.py`; verify no regressions.
- [ ] Commit Task 2 files with `git commit -m "feat: parse DMA task batches"`.

---

### Task 3: Serialize result records with a final trailer

**Files:**
- Create: `rtl/dma_result_formatter.v`
- Create: `sim/tb_dma_result_formatter.sv`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Consumes: batch metadata, task result metadata, a 32-bit result word stream, and `batch_finish` counters/status.
- Produces: `m_axis_result_tdata[127:0]`, `tkeep[15:0]`, `tvalid`, `tlast`; `TLAST` appears only on the last valid byte of the `MOLE` trailer.

- [ ] Write a failing test for a batch containing results of 1, 4, and 3200 words; reconstruct all output words and compare with a golden vector.
- [ ] Add stalls on every possible output beat, verify output remains stable while stalled, and cover final beat widths of 1/2/3/4 words.
- [ ] Run `python sim/run_tests.py --test dma_formatter`; verify missing-module failure.
- [ ] Implement a 32-bit word source mux and four-lane 128-bit packer. Emit the immutable eight-word `MOLR` header before the first task result.
- [ ] Emit each eight-word task result header followed by exactly `result_words` payload words.
- [ ] Emit the eight-word `MOLE` trailer with computed `completed_count`, `error_count`, `total_result_words`, `batch_status`, and first failing job ID.
- [ ] Reject a task before reading result payload if its declared result would exceed `max_result_words`; emit `RESULT_OVERFLOW` without overrunning the S2MM buffer.
- [ ] Run focused randomized tests and the full regression.
- [ ] Commit Task 3 files with `git commit -m "feat: format DMA batch results"`.

---

### Task 4: Add shared-query Tanimoto batching

**Files:**
- Create: `rtl/tanimoto_stream_batch.v`
- Create: `sim/tb_tanimoto_stream_batch.sv`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Consumes: 32 query words once, then `32*N` candidate words for `N=1..64`, plus start/abort and payload ready/valid.
- Produces: `N` ordered Q16.16 result words with ready/valid and one done pulse; no DSP usage.

- [ ] Write a failing test that compares N=1, N=2, and N=64 output against a SystemVerilog software popcount/divide reference and the existing task-0 result format.
- [ ] Include identical, disjoint, one-third, all-zero, alternating-bit, and randomized fingerprints.
- [ ] Run the focused test and verify the module is missing.
- [ ] Implement query storage, candidate accumulation, intersection/union popcounts, and the same fixed-point reciprocal/division behavior used by the validated Tanimoto core.
- [ ] Ensure candidate payload can be accepted continuously except when the result sink applies backpressure; do not buffer 64 complete candidates.
- [ ] Add assertions that exactly 32 words form each fingerprint and exactly N results are emitted.
- [ ] Run the focused test, `python sim/run_tests.py`, and a synthesis-only module utilization check confirming zero additional DSPs.
- [ ] Commit Task 4 files with `git commit -m "feat: batch shared-query Tanimoto jobs"`.

---

### Task 5: Schedule mixed tasks and define failure recovery

**Files:**
- Create: `rtl/dma_task_queue.v`
- Create: `sim/tb_dma_task_queue.sv`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Consumes: normalized frontend events and four backend ready/done/result interfaces.
- Produces: backend load/start signals, formatter metadata/result stream, `dma_active`, and legacy-start rejection pulse.

- [ ] Build a failing test with stub task backends for ordered mixed sequences of 1, 2, and 64 tasks; encode latency and error behavior per stub.
- [ ] Verify `job_id`, task ID, `user_tag`, item count, result count, and result ordering under random frontend and formatter stalls.
- [ ] Add timeout, unsupported task, insufficient result capacity, continue-on-error, stop-on-error, and abort/drain recovery tests.
- [ ] Run `python sim/run_tests.py --test dma_queue`; verify failure before implementation.
- [ ] Implement one in-flight compute task, bounded metadata registers, 64-bit compute-cycle count, configurable timeout (`0` maps to a fixed hardware default), and saturating/error-safe counters.
- [ ] Implement loaders that map task payload indexes to existing query, database, adjacency, feature, descriptor, and task-specific batch streams without changing numerical representation.
- [ ] Latch result metadata before offering it to the formatter; do not release core ownership until every expected result word is accepted.
- [ ] Implement deterministic abort: stop issuing new starts, discard the declared current payload, drain input to `TLAST`, close output with `MOLE`, then return idle.
- [ ] Run focused tests with at least 20 seeds and the complete regression.
- [ ] Commit Task 5 files with `git commit -m "feat: schedule mixed DMA accelerator tasks"`.

---

### Task 6: Integrate the queue with real compute cores and preserve legacy behavior

**Files:**
- Modify: `rtl/generator_accelerator_top.v`
- Modify: `sim/tb_top.sv`
- Create: `sim/tb_top_dma.sv`
- Modify: `sim/run_tests.py`

**Interfaces:**
- Adds top ports `s_axis_job_tdata[127:0]`, `s_axis_job_tkeep[15:0]`, `s_axis_job_tvalid`, `s_axis_job_tready`, `s_axis_job_tlast`, and matching `m_axis_result_*` ports.
- Preserves every existing AXI-Lite port, address, register behavior, and result value.

- [ ] First extend `tb_top.sv` with a check that all old register transactions still work when the new stream input is idle; run and confirm the unchanged design passes.
- [ ] Add failing `tb_top_dma.sv` cases for task 0, task 1 summary/full output, task 2 N=1/64, task 3 summary/intermediate/full, and a mixed 0/1/2/3 batch.
- [ ] Add arbitration tests: DMA input holds back while legacy execution is active; an AXI-Lite start during DMA sets legacy `LEGACY_BUSY` without corrupting the DMA batch.
- [ ] Connect queue loader/start/result interfaces to the existing compute memories and cores. Use muxes on control/address/write-data signals and a single registered owner; never instantiate a second GNN or ADMET datapath.
- [ ] Preserve sticky status clear, busy rejection, timeout behavior, and every legacy register address.
- [ ] Run `python sim/run_tests.py`; require all original nine tests plus all new tests to pass.
- [ ] Run an RTL synthesis utilization report and confirm accelerator DSP count remains `<= 80`.
- [ ] Commit Task 6 files with `git commit -m "feat: integrate DMA queue with accelerator cores"`.

---

### Task 7: Repackage the accelerator IP with AXIS interfaces

**Files:**
- Create: `FPGA/package_dma_accelerator_ip.tcl`
- Modify through script: `ip_repo/generator_accelerator_1_0/component.xml`
- Copy through script: new generated/RTL sources into `ip_repo/generator_accelerator_1_0/hdl/`

**Interfaces:**
- Produces IP bus interfaces named `s_axis_job` and `m_axis_result`, both 128-bit with `TDATA`, `TKEEP`, `TLAST`, `TVALID`, and `TREADY`, associated with `s_axi_aclk`/`s_axi_aresetn`.

- [ ] Add a script preflight that aborts unless all source files and generated protocol header exist.
- [ ] Make the script copy exact RTL sources, open the existing IP, merge/check file groups, infer or explicitly map both AXIS interfaces, update checksums, and save the core.
- [ ] Run Vivado batch packaging and require `ipx::check_integrity` to report no errors.
- [ ] Run a second packaging pass and verify `git diff` is unchanged, proving determinism.
- [ ] Inspect `component.xml` for all five signals on each stream and the correct 128-bit width.
- [ ] Commit the script, packaged source copies, and component metadata with `git commit -m "build: package accelerator DMA streams"`.

---

### Task 8: Build the Zynq HP0/DMA/FIFO Block Design

**Files:**
- Create: `FPGA/add_dma_batch_system.tcl`
- Create: `FPGA/check_dma_batch_bd.tcl`
- Modify through scripts: `FPGA/FPGA.srcs/sources_1/bd/system/system.bd`

**Interfaces:**
- Legacy control: PS `M_AXI_GP0` -> existing custom AXI3-to-AXI-Lite bridge -> accelerator `s_axi` at `0x43C00000`.
- DMA control: PS `M_AXI_GP1` -> second custom bridge -> DMA `S_AXI_LITE` at `0x40400000`.
- Data: DMA `M_AXI_MM2S`/`M_AXI_S2MM` -> SmartConnect -> PS `S_AXI_HP0`; AXIS channels pass through 128-bit FIFOs.

- [ ] Implement a read-only checker first; run it against the current BD and verify it fails because DMA, HP0, FCLK1, FIFOs, and stream connections are absent.
- [ ] In the construction script, assert the expected current PS, bridge, reset, and accelerator cells before mutation; abort on a mismatched design.
- [ ] Remove or disconnect the large `system_ila` from the production BD while preserving the existing working GP0 bridge path.
- [ ] Enable `M_AXI_GP1`, `S_AXI_HP0`, `FCLK_CLK1`, and 150 MHz FPGA1 clock in `processing_system7_0`.
- [ ] Create AXI DMA in Simple Mode with MM2S/S2MM enabled, SG/DRE disabled, 64-bit memory map width, 128-bit stream width, 23-bit length, and asynchronous clocks.
- [ ] Create a second `ps_axi3_to_axil_bridge` for DMA control, a data SmartConnect with two slave inputs/one master output, 512-beat input FIFO, 256-beat output FIFO, a 150 MHz `proc_sys_reset`, and an interrupt concat.
- [ ] Wire clocks/resets by domain: 100 MHz control/stream, 150 MHz memory/HP0. Connect both DMA IRQs to PS `IRQ_F2P`.
- [ ] Assign/lock the accelerator and DMA control addresses; run `assign_bd_address` only for unassigned segments and assert the final addresses.
- [ ] Run `validate_bd_design`, save, regenerate targets, then run the checker. Require no error or critical warning and exactly one driven clock/reset on every AXI pin.
- [ ] Commit Tcl scripts and the generated BD metadata with `git commit -m "build: add AXI DMA and HP0 data path"`.

---

### Task 9: Build packets and parse results safely in software

**Files:**
- Create: `software/baremetal/src/mol_dma_queue.h`
- Create: `software/baremetal/src/mol_dma_queue.c`
- Create: `software/tests/test_mol_dma_layout.py`
- Modify: `software/baremetal/src/accelerator.h`
- Modify: `software/baremetal/src/accelerator.c`

**Interfaces:**
- Consumes: caller-provided 64-byte-aligned TX/RX buffers and task payload arrays.
- Produces: bounds-checked packet builder operations, DMA submit/wait/reset, and a zero-copy result iterator keyed by `job_id`/`user_tag`.

- [ ] Write host-side failing golden-vector tests for empty rejection, one task of each type, 64 mixed tasks, maximum buffer bounds, all flags, and byte-for-byte request layout.
- [ ] Define fixed-width public types and error returns; never cast a packed network buffer to an alignment-sensitive C struct.
- [ ] Implement little-endian `put_u32/get_u32`, checked size arithmetic, 64-byte alignment validation, exact payload/result-capacity formulas, and finalization that writes `task_count` and `total_words` only after all tasks are added.
- [ ] Implement result parsing that validates `MOLR`, each record boundary/status/result size, the `MOLE` trailer, total words, counts, batch ID, and absence of trailing data.
- [ ] Implement XAxiDma Simple Mode lifecycle: look up/configure, disable SG expectation, reset with timeout, start S2MM before MM2S, poll or ISR completion, report channel error bits, and reset on failure.
- [ ] Flush TX before transfer; flush/invalidate RX before start as required by the BSP and invalidate RX again after completion.
- [ ] Keep legacy APIs unchanged and add only explicit weight-configuration helpers needed by the new app.
- [ ] Run `python software/tests/test_mol_dma_layout.py` and full regressions.
- [ ] Commit Task 9 files with `git commit -m "feat: add bare-metal DMA queue driver"`.

---

### Task 10: Create a reproducible Vitis DMA batch application

**Files:**
- Create: `software/baremetal/src/main_dma_batch.c`
- Create: `software/create_dma_vitis_app.tcl`
- Create/update through script: `vitis_workspace/accelerator_dma_batch/`
- Preserve: `vitis_workspace/accelerator_selftest/`

**Interfaces:**
- Consumes: exported candidate XSA, `xaxidma` BSP driver, UART0 on MIO14/15 at 115200 8N1.
- Produces: `accelerator_dma_batch.elf` and parseable UART lines for correctness, bandwidth, latency, acceleration, and stress counts.

- [ ] Write application-side pure builder/parser self-tests first and make the application return nonzero before any hardware transfer if they fail.
- [ ] Create a new application instead of modifying the known-good legacy self-test; copy canonical sources and generated protocol header from `software/baremetal/src`.
- [ ] Add functional cases matching the comprehensive legacy vectors: three Tanimoto references, GNN output[0]=1.0000, four ADMET outputs=0.7305, and Pipeline output equivalence.
- [ ] Add a single mixed 0/1/2/3 batch, Tanimoto shared-query N=64, ADMET N=64, GNN summary/full, Pipeline intermediate/full, continue-on-error, stop-on-error, timeout, and recovery cases.
- [ ] Add continuous 1000-batch stress with monotonically changing batch IDs and deterministic payload hashes.
- [ ] Print timing in this fixed schema:

```text
PERF name=<name> tasks=<n> tx=<bytes> rx=<bytes> us=<time> MBps=<rate> speedup=<ratio>
```

- [ ] Generate the platform/application from Tcl and build Debug and Release. Require zero compile/link errors and save `.elf.size` output.
- [ ] Commit canonical sources and creation Tcl; exclude generated workspace intermediates unless already tracked.

---

### Task 11: Synthesize, implement, and gate candidate artifacts

**Files:**
- Create: `FPGA/rebuild_dma_batch.tcl`
- Create: `FPGA/check_dma_reports.py`
- Create/update: `reports/dma_batch/rtl/`, `reports/dma_batch/impl/`, `artifacts/candidate_dma_batch/`
- Do not replace: `artifacts/system_wrapper_custom_bridge_ila.bit`, `.ltx`, or stable `.xsa` yet.

**Interfaces:**
- Consumes: packaged IP and validated DMA BD.
- Produces: candidate bitstream/XSA plus utilization, timing, DRC, clock, and route reports.

- [ ] Write the report checker first using synthetic failing reports for negative WNS/WHS, DRC errors, DSP >80, or missing 100/150 MHz clocks.
- [ ] Adapt the known-good rebuild flow to sync sources, package IP, update BD, reset runs, synthesize, implement, and export only to `artifacts/candidate_dma_batch/`.
- [ ] Run RTL/full synthesis and verify no inferred-memory failure, no multi-driven nets, no latch warnings in new queue modules, and DSP `<=80`.
- [ ] Run implementation without the production ILA and capture timing by clock, utilization hierarchy, route status, methodology DRC, and standard DRC.
- [ ] Gate promotion on `WNS>=0`, `WHS>=0` for both 100 MHz and 150 MHz domains, DRC Error=0, complete route, DSP<=80, and device resource limits.
- [ ] If 150 MHz alone fails after placement/physical optimization, record the failing path, change FCLK1 and its constraints to 125 MHz, rebuild from synthesis, and re-run all bandwidth targets; do not silently lower the clock.
- [ ] Run `python FPGA/check_dma_reports.py reports/dma_batch/impl`; require exit code 0.
- [ ] Commit scripts and text reports, excluding large generated run directories, with `git commit -m "build: gate DMA batch implementation"`.

---

### Task 12: Program the board, measure targets, and promote the release

**Files:**
- Create: `FPGA/program_dma_batch.tcl`
- Create: `FPGA/run_dma_batch_debug.tcl`
- Create/update: `reports/dma_batch/board-results.txt`
- Create/update: `reports/dma_batch/performance.md`
- Update after all gates pass: `artifacts/system_wrapper_dma_batch.bit`
- Update after all gates pass: `artifacts/system_wrapper_dma_batch.xsa`
- Update: project acceptance Word document identified from the approved project-purpose materials.

**Interfaces:**
- Consumes: powered Z15 board, JTAG cable, UART0 cable, candidate bitstream/XSA/ELF.
- Produces: reproducible XSCT programming scripts, UART evidence, final performance table, and promoted release artifacts.

- [ ] Program the candidate bitstream, initialize PS7, download the Release ELF to Cortex-A9 #0, and start execution using one Tcl command file.
- [ ] Capture UART output for single-task equivalence, mixed task order, N=64 batches, all protocol/error cases, DMA reset recovery, cache-enabled correctness, and 1000 consecutive batches.
- [ ] Measure standalone MM2S and S2MM effective bandwidth using multi-megabyte legal buffers; require each reported direction to be at least 500 MB/s.
- [ ] Measure end-to-end baselines and DMA batches with the same inputs and timer source. Require GNN >10x, ADMET N=64 >20x, Pipeline >30x, shared-query Tanimoto N=64 >=20x, and pure compute Tanimoto >50x.
- [ ] If a mandatory target fails, preserve the evidence, profile transfer/queue/core phases separately, make the smallest RTL/software optimization, and repeat Tasks 6-12 from the first affected gate.
- [ ] Run a final clean regression and report gate, then compare candidate hashes against the programmed files.
- [ ] Promote candidate `.bit` and `.xsa` only after every mandatory gate passes; retain an `.ltx` only for an explicitly labeled debug build.
- [ ] Update the acceptance Word document with architecture, protocol, resource/timing tables, UART logs, measured bandwidth, end-to-end speedups, and an honest note that Tanimoto >50x end-to-end is a stretch target if only the >=20x mandatory goal is reached.
- [ ] Render and visually inspect the final Word document before delivery.
- [ ] Commit reports, scripts, document, and promoted artifact metadata with `git commit -m "test: validate DMA batch accelerator on board"`.

---

## Final Verification Checklist

- [ ] `python tools/generate_dma_protocol.py --check` succeeds.
- [ ] `python sim/run_tests.py` passes the original nine and every new RTL test.
- [ ] Vivado IP integrity and `validate_bd_design` report no errors or critical warnings.
- [ ] Implemented WNS/WHS are nonnegative for both clock domains; DRC errors are zero; DSP count is at most 80.
- [ ] Legacy comprehensive board self-test still prints `ALL COMPREHENSIVE SELF-TESTS PASSED`.
- [ ] DMA application passes mixed, 64-task, error/recovery, cache, and 1000-batch tests.
- [ ] Effective MM2S and S2MM bandwidth are each at least 500 MB/s.
- [ ] Mandatory GNN, ADMET, Pipeline, Tanimoto batch, and pure-compute acceleration targets are met and reported from measured data.
- [ ] Stable artifacts are replaced only after all preceding checks pass.
