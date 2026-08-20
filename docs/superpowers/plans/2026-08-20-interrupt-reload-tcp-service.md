# Interrupt-Driven DMA Weight Reload and TCP Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Z15 上交付中断式 AXI DMA、`0xFE` 权重热重载和符合文档帧格式的 TCP 5001 加速服务。

**Architecture:** 保留现有 Standalone、AXI DMA simple mode 和 canonical DMA batch 协议。TCP 层只负责帧解析、8 项 FIFO 和响应编码，所有计算及权重更新统一转换为现有 DMA batch；RTL 为 `0xFE` 增加专用权重写路径，PS 通过 DMA 中断完成任务。

**Tech Stack:** Verilog/SystemVerilog、Python 3、C11、Vivado/Vitis 2019.2、Standalone BSP、lwIP 2.0.2 raw API、XScuGic、AXI DMA、Icarus Verilog。

**Spec:** `docs/方案三_中断_DMA热重载_TCP服务_设计.md`

## Global Constraints

- 目标器件固定为 XC7Z015，Vivado/Vitis 固定为 2019.2。
- PS 软件固定为 Standalone + lwIP raw API，不增加 FreeRTOS 或第三方运行时。
- TCP 固定端口 5001，静态地址 `192.168.1.10/24`，网关 `192.168.1.1`，MAC `02:00:00:00:70:15`。
- 网络帧头固定 16 字节、little-endian；请求 magic `0x5A`、version `1`。
- 请求 FIFO 固定 8 项，每项 24 KiB；最多 5 个 TCP 连接，所有完整请求按全局 FIFO 顺序执行。
- 热重载固定 9,076 个 signed Q8.8 权重，即 4,538 words / 18,152 bytes。
- 保留 128-bit AXI4-Stream、16-beat burst、HP0 和已有 DMA/UART 自测。
- 不提交 Vivado/Vitis 生成目录；只提交 canonical 源码、脚本、测试、正式 artifacts 和报告。
- 用户当前删除的 `reports/verification_report.md` 不恢复、不暂存、不提交。

---

### Task 1: Extend the canonical DMA protocol with weight reload

**Files:**
- Modify: `protocol/mol_dma_protocol.json`
- Modify: `tools/generate_dma_protocol.py`
- Modify: `sim/test_dma_protocol_codegen.py`
- Modify: `software/tests/test_mol_dma_layout.py`
- Modify: `software/baremetal/src/mol_dma_queue.c`
- Generated: `rtl/mol_dma_protocol.vh`
- Generated: `software/baremetal/src/mol_dma_protocol.h`

**Interfaces:**
- Produces: `MOL_DMA_TASK_WEIGHT_RELOAD == 0xFE`
- Produces: `MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD == 4538`
- Produces: `mol_dma_required_words(0xFE, 0, 1) -> payload=4538, result=1`
- Consumed by: RTL frontend/backend, startup loader, TCP dispatcher, PC client

- [ ] **Step 1: Write failing protocol and layout tests**

Add these exact expectations to `EXPECTED_CONSTANTS` in `sim/test_dma_protocol_codegen.py`:

```python
"TASK_WEIGHT_RELOAD": 0xFE,
"PAYLOAD_WORDS_WEIGHT_RELOAD": 4538,
```

Add a `WEIGHT_RELOAD = 0xFE` case to `task_requirements()` and include it in `test_byte_exact_one_task_of_each_type()`:

```python
if task_id == WEIGHT_RELOAD:
    if flags != 0 or count != 1:
        raise ValueError("invalid reload request")
    return 4538, 1
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```powershell
py -3 sim/test_dma_protocol_codegen.py
py -3 software/tests/test_mol_dma_layout.py
```

Expected: codegen test reports missing `TASK_WEIGHT_RELOAD`; layout test reports the reload task is rejected.

- [ ] **Step 3: Extend the canonical JSON and generator validation**

Add the following JSON entries:

```json
"task_ids": {
  "tanimoto": 0,
  "gnn": 1,
  "admet": 2,
  "pipeline": 3,
  "weight_reload": 254
},
"payload_words": {
  "weight_reload": 4538
}
```

Replace the contiguous task-ID assertion in `validate_spec()` with:

```python
task_values = {parse_integer(value) for value in task_ids.values()}
if task_values != {0, 1, 2, 3, 0xFE}:
    raise ValueError("task IDs must be 0..3 plus weight reload 0xFE")
```

- [ ] **Step 4: Extend C builder and response validation**

Add a dedicated case to `mol_dma_required_words()` and `valid_success_result_size()`:

```c
case MOL_DMA_TASK_WEIGHT_RELOAD:
    if (flags != 0U || item_count != 1U) {
        return MOL_DMA_ERR_RANGE;
    }
    *payload_words = MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
    *result_words = 1U;
    return MOL_DMA_OK;
```

```c
case MOL_DMA_TASK_WEIGHT_RELOAD:
    return item_count == 1U && result_words == 1U;
```

Change successful result task validation from a numeric upper-bound check to an explicit supported-task predicate so `0x04..0xFD` remain invalid.

- [ ] **Step 5: Regenerate headers and run checks**

Run:

```powershell
py -3 tools/generate_dma_protocol.py
py -3 sim/test_dma_protocol_codegen.py
py -3 software/tests/test_mol_dma_layout.py
py -3 sim/run_tests.py --test protocol
```

Expected: all commands pass and generated C/Verilog constants match.

- [ ] **Step 6: Commit protocol support**

```powershell
git add protocol/mol_dma_protocol.json tools/generate_dma_protocol.py sim/test_dma_protocol_codegen.py software/tests/test_mol_dma_layout.py software/baremetal/src/mol_dma_queue.c rtl/mol_dma_protocol.vh software/baremetal/src/mol_dma_protocol.h
git commit -m "feat: define DMA weight reload task"
```

---

### Task 2: Implement and verify RTL weight streaming

**Files:**
- Create: `sim/tb_dma_weight_reload.sv`
- Modify: `sim/run_tests.py`
- Modify: `rtl/dma_task_queue_frontend.v`
- Modify: `rtl/dma_accelerator_backend.v`
- Modify: `rtl/generator_accelerator_top.v`

**Interfaces:**
- Consumes: task `0xFE`, 4,538 little-endian words
- Produces: `gnn_weight_we/addr/wdata` and `admet_cfg_we/model/layer/addr/wdata`
- Produces: one result word containing a hardware reload completion counter

- [ ] **Step 1: Create the failing end-to-end RTL test**

Create `tb_dma_weight_reload.sv` using the existing packet-driving pattern. Monitor the backend's GNN and ADMET configuration outputs, send one legal reload whose payload word `i` contains value `2*i` in the low half and `2*i+1` in the high half, and assert:

```systemverilog
if (gnn_write_count !== 8192 ||
    first_gnn_addr !== 0 || first_gnn_data !== 16'd0 ||
    last_gnn_addr !== 8191 || last_gnn_data !== 16'd8191)
    $fatal(1, "GNN reload ordering mismatch");
if (admet_write_count !== 884 ||
    last_admet_model !== 3 || last_admet_layer !== 3 ||
    last_admet_addr !== 0 || last_admet_data !== 16'd9075)
    $fatal(1, "ADMET final weight mismatch");
if (result_task_id !== `MOL_DMA_TASK_WEIGHT_RELOAD ||
    result_status !== `MOL_DMA_STATUS_OK || result_words !== 1)
    $fatal(1, "reload response mismatch");
```

Also send reload frames with 4,537 words, nonzero flags, and item count 2; expect `BAD_LENGTH`, `BAD_FLAGS`, and `BAD_ITEM_COUNT` respectively.

- [ ] **Step 2: Register and run the failing RTL test**

Add `dma_weight_reload` to `TESTS` in `sim/run_tests.py` with the explicit source list `tanimoto_accelerator.v`, `gnn_message_passing.v`, `fc_network.v`, `admet_predictor.v`, `tanimoto_stream_batch.v`, `dma_task_queue_frontend.v`, `dma_task_queue.v`, `dma_result_formatter.v`, `dma_accelerator_backend.v`, `generator_accelerator_top.v`, and `tb_dma_weight_reload.sv`.

Run:

```powershell
py -3 sim/run_tests.py --test dma_weight_reload
```

Expected: compile or assertion failure because `0xFE` is not implemented.

- [ ] **Step 3: Add explicit frontend validation**

Replace `id > MOL_DMA_TASK_PIPELINE` with an explicit supported-ID expression and add:

```verilog
`MOL_DMA_TASK_WEIGHT_RELOAD: begin
    allowed_flags = 32'd0;
    if (item_count_value != 1)
        checked_task_status = `MOL_DMA_STATUS_BAD_ITEM_COUNT;
    required_payload = `MOL_DMA_PAYLOAD_WORDS_WEIGHT_RELOAD;
    required_result = 32'd1;
end
```

Keep the Pipeline branch explicit instead of using `default`, so unknown IDs cannot inherit Pipeline sizing.

- [ ] **Step 4: Add backend half-word sequencing**

Add outputs to `dma_accelerator_backend`:

```verilog
output reg         gnn_weight_we,
output reg [12:0]  gnn_weight_addr,
output reg [15:0]  gnn_weight_wdata,
output reg         admet_cfg_we,
output reg [1:0]   admet_cfg_model,
output reg [1:0]   admet_cfg_layer,
output reg [15:0]  admet_cfg_addr,
output reg [15:0]  admet_cfg_wdata
```

For reload, latch each payload word, deassert `payload_ready`, write the low half, then the high half. Map linear index 0..8191 to GNN; map 8192..9075 to model/layer/address using fixed counts 200/10/10/1. Increment a 32-bit `reload_epoch` only after index 9075 is written, then return it as the sole result word. `abort` clears the partial state without incrementing epoch.

- [ ] **Step 5: Mux DMA and AXI-Lite configuration ports in the top**

Connect the new backend outputs and define:

```verilog
wire core_gnn_weight_we = dma_active ? dma_gnn_weight_we : gnn_weight_we;
wire [GNN_WEIGHT_ADDR_W-1:0] core_gnn_weight_addr =
    dma_active ? dma_gnn_weight_addr : gnn_weight_addr;
wire [DATA_WIDTH-1:0] core_gnn_weight_wdata =
    dma_active ? dma_gnn_weight_wdata : gnn_weight_data_reg;
wire core_admet_cfg_we = dma_active ? dma_admet_cfg_we : admet_cfg_we;
```

Use the corresponding DMA/AXI-Lite selections for ADMET model, layer, address and data. Connect only the selected wires to `u_gnn` and `u_admet`.

- [ ] **Step 6: Run focused and full RTL regressions**

Run:

```powershell
py -3 sim/run_tests.py --test dma_weight_reload
py -3 sim/run_tests.py --test top_dma_arbitration
py -3 sim/run_tests.py --test all
```

Expected: reload test passes; all previous RTL and protocol tests remain green.

- [ ] **Step 7: Commit RTL reload support**

```powershell
git add rtl/dma_task_queue_frontend.v rtl/dma_accelerator_backend.v rtl/generator_accelerator_top.v sim/tb_dma_weight_reload.sv sim/run_tests.py
git commit -m "feat: stream model weights through DMA"
```

---

### Task 3: Replace DMA completion polling with interrupts

**Files:**
- Modify: `software/baremetal/src/mol_dma_queue.h`
- Modify: `software/baremetal/src/mol_dma_queue.c`
- Modify: `software/tests/test_mol_dma_layout.py`
- Modify: `software/baremetal/src/main_dma_batch.c`

**Interfaces:**
- Produces: `mol_dma_device_connect_irqs(device, mm2s_id, s2mm_id)`
- Produces: `mol_dma_transfer_irq_ex(..., timeout_ticks, progress, context, ...)`
- Preserves: `mol_dma_transfer_poll_ex()` as a compatibility wrapper that calls the interrupt implementation only when the device has IRQs connected

- [ ] **Step 1: Add failing host tests for IRQ state transitions**

Expose this portable state in `mol_dma_queue.h`, outside the Xilinx-only guard:

```c
typedef struct {
    volatile uint32_t mm2s_done;
    volatile uint32_t s2mm_done;
    volatile uint32_t error;
} mol_dma_irq_state_t;

#define MOL_DMA_IRQ_IOC   UINT32_C(1)
#define MOL_DMA_IRQ_ERROR UINT32_C(2)

void mol_dma_irq_record(mol_dma_irq_state_t *state, uint32_t direction,
                        uint32_t irq_status);
int mol_dma_irq_complete(const mol_dma_irq_state_t *state);
```

Extend the ctypes host test to assert: one completion remains pending, both completions return true, and either channel error records `error=1`.

- [ ] **Step 2: Run the host test and verify failure**

Run:

```powershell
py -3 software/tests/test_mol_dma_layout.py
```

Expected: shared library lacks `mol_dma_irq_record` and `mol_dma_irq_complete`.

- [ ] **Step 3: Implement the portable IRQ state helper**

Use direction values `0` for MM2S and `1` for S2MM; the hardware ISR translates Xilinx masks into the two portable event bits before recording them:

```c
void mol_dma_irq_record(mol_dma_irq_state_t *state, uint32_t direction,
                        uint32_t irq_status)
{
    if ((irq_status & MOL_DMA_IRQ_ERROR) != 0U) state->error = 1U;
    if ((irq_status & MOL_DMA_IRQ_IOC) != 0U) {
        if (direction == 0U) state->mm2s_done = 1U;
        else state->s2mm_done = 1U;
    }
}
```

`mol_dma_irq_complete()` returns true only when both done flags are set and error is clear.

- [ ] **Step 4: Connect XScuGic and enable AXI DMA interrupts**

Add IRQ IDs and state to `mol_dma_device_t`. Each ISR must read `XAxiDma_IntrGetIrq()`, acknowledge exactly those bits with `XAxiDma_IntrAckIrq()`, and call the portable recorder. Register both handlers through the Zynq GIC, set priority/trigger type, enable `XAXIDMA_IRQ_IOC_MASK | XAXIDMA_IRQ_ERROR_MASK`, and enable CPU exceptions once.

- [ ] **Step 5: Implement bounded interrupt transfer**

Declare:

```c
typedef void (*mol_dma_progress_fn)(void *context);
int mol_dma_transfer_irq_ex(mol_dma_device_t *device,
    const void *tx_buffer, size_t tx_bytes,
    void *rx_buffer, size_t rx_capacity_bytes,
    uint32_t expected_batch_id, uint64_t timeout_ticks,
    mol_dma_progress_fn progress, void *context,
    size_t *response_bytes, uint32_t transfer_flags);
```

The implementation must arm S2MM before MM2S, wait on volatile ISR flags, call `progress(context)` once per wait iteration when non-null, compare `XTime_GetTime()` against the deadline, reset both channels on error/timeout, then invalidate and parse the response. Remove DMA status-register polling from the normal completion path.

- [ ] **Step 6: Update the board self-test to use IRQ IDs 61/62**

In `main_dma_batch.c`, connect:

```c
mol_dma_device_connect_irqs(
    &dma,
    XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR,
    XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR);
```

Route every batch through `mol_dma_transfer_irq_ex()` and print MM2S/S2MM interrupt counters in the final summary.

- [ ] **Step 7: Run host tests and Vitis compile**

Run:

```powershell
py -3 software/tests/test_mol_dma_layout.py
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' software/rebuild_dma_vitis_app.tcl
```

Expected: host tests pass; Debug and Release ELF files build without warnings promoted to errors.

- [ ] **Step 8: Commit interrupt DMA support**

```powershell
git add software/baremetal/src/mol_dma_queue.h software/baremetal/src/mol_dma_queue.c software/baremetal/src/main_dma_batch.c software/tests/test_mol_dma_layout.py
git commit -m "feat: complete AXI DMA transfers by interrupt"
```

---

### Task 4: Build the host-testable TCP frame codec and 8-entry FIFO

**Files:**
- Create: `software/baremetal/src/mol_tcp_protocol.h`
- Create: `software/baremetal/src/mol_tcp_protocol.c`
- Create: `software/tests/test_mol_tcp_protocol.py`

**Interfaces:**
- Produces: `mol_tcp_decode_header()`, `mol_tcp_encode_header()`
- Produces: `mol_tcp_request_queue_push()`, `mol_tcp_request_queue_pop()`
- Produces: fixed constants `MOL_TCP_HEADER_BYTES=16`, `MOL_TCP_QUEUE_DEPTH=8`, `MOL_TCP_SLOT_BYTES=24576`

- [ ] **Step 1: Write failing golden-vector and FIFO tests**

Compile `mol_tcp_protocol.c` as a host DLL. Use this exact golden request:

```python
header = bytes.fromhex("5a 01 00 00 00 01 00 00 78 56 34 12 02 00 00 00")
```

Assert it decodes to task 0, payload length 256, trace `0x12345678`, batch 2. Add tests for split input assembly, two frames in one byte stream, bad magic/version/flags, payload length mismatch, batch 0/65, and `0xFE` length 18,152.

Push traces 0..7 and assert pop order 0..7; the ninth push must return `MOL_TCP_BUSY`. Reuse a connection slot with a new generation and assert the old queued item is marked disconnected.

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```powershell
py -3 software/tests/test_mol_tcp_protocol.py
```

Expected: compile failure because the codec does not exist.

- [ ] **Step 3: Implement the exact wire header**

Define:

```c
typedef struct {
    uint8_t task_id;
    uint8_t flags;
    uint32_t payload_len;
    uint32_t trace_id;
    uint32_t batch_size;
} mol_tcp_header_t;
```

Decode fields byte-by-byte to avoid unaligned loads. Reject request response/busy/error/fallback bits, high reserved bits, unsupported task IDs, wrong task-specific payload sizes, and invalid batch sizes. Encode responses with bit0 set and only documented response flags.

Define stable network error payload codes:

```c
enum {
    MOL_TCP_ERR_BAD_HEADER = 1,
    MOL_TCP_ERR_BAD_LENGTH = 2,
    MOL_TCP_ERR_BAD_TASK = 3,
    MOL_TCP_ERR_BAD_BATCH = 4,
    MOL_TCP_ERR_QUEUE_FULL = 5,
    MOL_TCP_ERR_WEIGHTS_NOT_READY = 6,
    MOL_TCP_ERR_DMA = 7,
    MOL_TCP_ERR_RELOAD = 8,
    MOL_TCP_ERR_INTERNAL = 9
};
```

Every error/busy response carries exactly two little-endian u32 words: one enum value and one detail value.

- [ ] **Step 4: Implement fixed FIFO storage**

Define eight statically allocated slots containing header, connection slot, connection generation, payload length, and 24 KiB payload. Maintain only `head`, `tail`, and `count`. Reject a full queue before copying payload. Zero only metadata on pop; payload is overwritten by the next push.

- [ ] **Step 5: Run the protocol tests under warnings-as-errors**

Run:

```powershell
py -3 software/tests/test_mol_tcp_protocol.py
```

Expected: all codec, stream assembly and FIFO tests pass with `-Wall -Wextra -Werror`.

- [ ] **Step 6: Commit the pure TCP core**

```powershell
git add software/baremetal/src/mol_tcp_protocol.h software/baremetal/src/mol_tcp_protocol.c software/tests/test_mol_tcp_protocol.py
git commit -m "feat: add TCP frame codec and request FIFO"
```

---

### Task 5: Enable GEM0 and make lwIP reproducibly support YT8531C

**Files:**
- Modify: `FPGA/add_dma_batch_system.tcl`
- Create: `software/patch_lwip_yt8531.py`
- Create: `software/tests/test_yt8531_patch.py`
- Create: `software/create_tcp_vitis_app.tcl`

**Interfaces:**
- Produces: XSA containing `ps7_ethernet_0`
- Produces: BSP with `lwip202`, raw API and patched generic Clause 22 PHY speed path
- Consumes: board PHY at MDIO address 7

- [ ] **Step 1: Write the failing idempotent PHY patch test**

Create a temporary copy of Vitis 2019.2 `xemacpsif_physpeed.c`; run the patcher twice and assert identical output. Assert the patched unknown-PHY branch calls `get_Generic_phy_speed()` and no longer defaults to `get_Marvell_phy_speed()`.

- [ ] **Step 2: Run the patch test and verify failure**

Run:

```powershell
py -3 software/tests/test_yt8531_patch.py
```

Expected: failure because the patcher does not exist.

- [ ] **Step 3: Enable PS GEM0 in the canonical Vivado script**

Add these exact PS7 properties to the existing `set_property -dict`:

```tcl
CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1}
CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27}
CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1}
CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53}
```

Do not assign a second Ethernet reset MIO: the Z15 schematic already ties PHY reset to the board reset network.

- [ ] **Step 4: Implement the minimal PHY source patch**

The patch inserts one function that starts Clause 22 auto-negotiation, waits with a finite loop, reads register 10 for 1000BASE-T partner ability and register 5 for 100/10 partner ability, then returns 1000/100/10. It changes only the unknown-identifier branch:

```c
else {
    RetStatus = get_Generic_phy_speed(xemacpsp, phy_addr);
}
```

It must leave TI, Realtek and Marvell paths untouched and fail if the expected Vitis source markers do not match.

- [ ] **Step 5: Create the TCP Vitis platform/app script**

Create/update `z15_tcp_platform` from the new XSA, select `standalone_domain`, add `lwip202`, configure raw API and DHCP off, regenerate BSP, apply the PHY patch to the generated BSP source, rebuild the BSP, then create `accelerator_tcp_server`. Import the canonical accelerator, DMA, TCP and server sources; build Debug and Release and assert both ELF files exist.

The script must use generated XSA identifiers rather than hard-coded base addresses and print:

```tcl
puts "TCP_DEBUG_ELF=$debug_elf"
puts "TCP_RELEASE_ELF=$release_elf"
```

- [ ] **Step 6: Run patch test and Vivado BD validation**

Run:

```powershell
py -3 software/tests/test_yt8531_patch.py
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source FPGA/add_dma_batch_system.tcl
```

Expected: patch test passes; BD validates and regenerated handoff exposes GEM0.

- [ ] **Step 7: Commit hardware/BSP configuration**

```powershell
git add FPGA/add_dma_batch_system.tcl software/patch_lwip_yt8531.py software/tests/test_yt8531_patch.py software/create_tcp_vitis_app.tcl
git commit -m "feat: enable GEM0 and YT8531C lwIP platform"
```

---

### Task 6: Implement weights_ready and the lwIP raw TCP server

**Files:**
- Create: `software/baremetal/src/main_tcp_server.c`
- Create: `FPGA/program_tcp_service.tcl`
- Modify: `software/baremetal/src/mol_tcp_protocol.h`
- Modify: `software/baremetal/src/mol_tcp_protocol.c`
- Modify: `software/baremetal/src/accelerator.h`
- Modify: `software/baremetal/src/accelerator.c`
- Modify: `software/create_tcp_vitis_app.tcl`
- Modify: `software/baremetal/README.md`

**Interfaces:**
- Listens: TCP `0.0.0.0:5001`
- Owns: `weights_ready`, `weights_epoch`, `reload_in_progress`
- Converts: one network frame to one canonical DMA batch and response

- [ ] **Step 1: Add failing host tests for request-to-DMA mapping**

Extend `test_mol_tcp_protocol.py` to call a pure mapping function:

```c
int mol_tcp_dma_shape(uint8_t task_id, uint32_t batch_size,
                      uint32_t *dma_flags, uint32_t *payload_words,
                      uint32_t *result_words);
```

Assert exact shapes: Tanimoto 1=`64/1`, Tanimoto 64=`2080/64` with shared-query, GNN=`1679/1`, ADMET 64=`1280/256`, Pipeline=`1763/4`, reload=`4538/1`.

- [ ] **Step 2: Run tests and verify mapping failure**

Run:

```powershell
py -3 software/tests/test_mol_tcp_protocol.py
```

Expected: missing `mol_tcp_dma_shape`.

- [ ] **Step 3: Implement reference weight packing through DMA**

Add `accel_pack_reference_weights(uint32_t words[4538])`. Initialize the array to zero, set GNN weight 0 to `0x0100`, and set each ADMET model's layer-0 address 0 and layer-2 address 0 to `0x0100`. Pack two signed 16-bit values per word, low half first. Startup must build a `0xFE` batch from this array and set ready only after a successful one-word reload response.

- [ ] **Step 4: Initialize lwIP raw networking**

In `main_tcp_server.c`, initialize caches/platform, DMA IRQs, lwIP, one `netif`, static IPv4 values, MAC, and `tcp_new()` listener. Bind to port 5001, call `tcp_listen()`, and register accept/recv/error callbacks. Maintain exactly five static connection slots; increment a slot generation each time it is reused.

- [ ] **Step 5: Implement stream callbacks and immediate busy/error responses**

The receive callback acknowledges bytes with `tcp_recved()`, accumulates a 16-byte header and declared payload across pbufs, and handles multiple complete frames in one callback. Complete frames from every connection enter the same FIFO; if it already has eight entries, encode and call `tcp_write()`/`tcp_output()` for a busy response without enqueueing. Bad magic/version/length returns an error and closes when frame boundaries are no longer trustworthy.

- [ ] **Step 6: Dispatch FIFO requests through canonical DMA**

For each dequeued item: check connection generation; reject GNN/ADMET/Pipeline when `weights_ready==0`; build a one-task DMA batch with `trace_id` as job/user tag; invoke `mol_dma_transfer_irq_ex()` with a progress callback that calls `xemacif_input()` and `sys_check_timeouts()`; parse the result and return only the documented network payload.

For `0xFE`, set `reload_in_progress=1` and `weights_ready=0` before DMA; on success copy returned epoch, set ready, clear in-progress; on any failure clear in-progress and leave ready zero. Tanimoto remains usable while weights are not ready.

- [ ] **Step 7: Build and run all host software tests**

Run:

```powershell
py -3 software/tests/test_mol_dma_layout.py
py -3 software/tests/test_mol_tcp_protocol.py
```

Expected: all tests pass.

- [ ] **Step 8: Build the Standalone lwIP application**

Run:

```powershell
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' software/create_tcp_vitis_app.tcl
```

Expected: both `accelerator_tcp_server.elf` configurations are generated and the map file fits DDR.

- [ ] **Step 9: Add the reproducible XSCT programming script**

Create `FPGA/program_tcp_service.tcl` from the existing proven target/reset sequence, using defaults `artifacts/system_wrapper_tcp_service.bit`, `vitis_workspace/z15_tcp_platform/hw/ps7_init.tcl`, and the TCP Release ELF. It must program PL before `ps7_init`, download to Cortex-A9 #0, continue execution, print both selected paths, disconnect and exit. Support `MOL_TCP_BIT` and `MOL_TCP_ELF` environment overrides.

- [ ] **Step 10: Commit the server**

```powershell
git add FPGA/program_tcp_service.tcl software/baremetal/src/main_tcp_server.c software/baremetal/src/mol_tcp_protocol.h software/baremetal/src/mol_tcp_protocol.c software/baremetal/src/accelerator.h software/baremetal/src/accelerator.c software/create_tcp_vitis_app.tcl software/baremetal/README.md software/tests/test_mol_tcp_protocol.py
git commit -m "feat: serve accelerator requests over TCP"
```

---

### Task 7: Add a deterministic PC client and protocol acceptance suite

**Files:**
- Create: `software/host/mol_tcp_client.py`
- Create: `software/host/test_mol_tcp_client.py`
- Create: `software/host/README.md`
- Create: `test_data/reference_weights.bin`

**Interfaces:**
- CLI: `py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest`
- CLI: `... reload weights.bin`
- File format: `weights.bin` is exactly 18,152 little-endian bytes

- [ ] **Step 1: Write failing client codec tests**

Use a local socket-pair/fake server to split the 16-byte response header into 1/3/12-byte chunks and the payload into arbitrary chunks. Assert `recv_exact()` reconstructs it. Test busy/error flags and a mismatched trace ID.

- [ ] **Step 2: Run and verify failure**

Run:

```powershell
py -3 software/host/test_mol_tcp_client.py
```

Expected: import failure because the client does not exist.

- [ ] **Step 3: Implement the standard-library-only client**

Use only `argparse`, `socket`, `struct`, `time`, and `pathlib`. Implement `pack_header()`, `recv_exact()`, `request()`, and subcommands `selftest`, `tanimoto`, `gnn`, `admet`, `pipeline`, `reload`, `queue-test`. Validate payload sizes before opening a socket and display trace, status, result words and wall-clock latency.

Add `pack-weights --output test_data/reference_weights.bin`. It reads the existing GNN and four-model ADMET `.mem` files in the exact ordering from the specification, parses each signed 16-bit hexadecimal line, and writes exactly 18,152 little-endian bytes. The command refuses any source with the wrong element count.

- [ ] **Step 4: Implement selftest and queue saturation**

`selftest` sends deterministic Tanimoto identical/disjoint/one-third inputs and checks `0x10000`, `0`, `0x5555`, then exercises GNN, ADMET and Pipeline. `queue-test` opens five connections, starts one GNN request to occupy the accelerator, then submits at least nine additional frames without waiting for individual responses. It verifies accepted traces return in global FIFO order and requires a busy response once all eight FIFO slots are occupied.

- [ ] **Step 5: Run client tests**

Run:

```powershell
py -3 software/host/test_mol_tcp_client.py
```

Expected: all fake-server and codec tests pass.

- [ ] **Step 6: Generate and verify the canonical reload payload**

Run:

```powershell
py -3 software/host/mol_tcp_client.py pack-weights --output test_data/reference_weights.bin
if ((Get-Item -LiteralPath test_data/reference_weights.bin).Length -ne 18152) { throw 'wrong weight payload size' }
```

- [ ] **Step 7: Commit the host client**

```powershell
git add software/host/mol_tcp_client.py software/host/test_mol_tcp_client.py software/host/README.md test_data/reference_weights.bin
git commit -m "test: add TCP accelerator acceptance client"
```

---

### Task 8: Rebuild hardware, program the board, and capture acceptance evidence

**Files:**
- Modify: `software/baremetal/README.md`
- Create: `reports/tcp_service/build-results.txt`
- Create: `reports/tcp_service/board-results.txt`
- Create/update: `artifacts/system_wrapper_tcp_service.bit`
- Create/update: `artifacts/system_wrapper_tcp_service.xsa`
- Create/update: `artifacts/accelerator_tcp_server.elf`

**Interfaces:**
- Produces: reproducible Vivado/Vitis artifacts and final PASS/FAIL evidence
- Requires: powered Z15, JTAG, UART0 USB cable and Ethernet cable

- [ ] **Step 1: Run all source-level regressions**

Run:

```powershell
py -3 sim/run_tests.py --test all
py -3 software/tests/test_mol_dma_layout.py
py -3 software/tests/test_mol_tcp_protocol.py
py -3 software/tests/test_yt8531_patch.py
py -3 software/host/test_mol_tcp_client.py
```

Expected: every command passes; record exact test counts in `build-results.txt`.

- [ ] **Step 2: Package IP and rebuild Vivado outputs**

Run:

```powershell
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source FPGA/package_dma_accelerator_ip.tcl
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source FPGA/add_dma_batch_system.tcl
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source FPGA/rebuild_dma_batch.tcl
Copy-Item -LiteralPath artifacts/candidate_dma_batch/system_wrapper_dma_batch.bit -Destination artifacts/system_wrapper_tcp_service.bit -Force
Copy-Item -LiteralPath artifacts/candidate_dma_batch/system_wrapper_dma_batch.xsa -Destination artifacts/system_wrapper_tcp_service.xsa -Force
```

Required report gates:

```text
route_status: ROUTED
WNS: > 0.000 ns
TNS: 0.000 ns
DRC errors: 0
```

- [ ] **Step 3: Rebuild the TCP Vitis application from the exported XSA**

Run:

```powershell
$env:MOL_DMA_XSA='D:\FPGA\artifacts\system_wrapper_tcp_service.xsa'
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' software/create_tcp_vitis_app.tcl
```

Copy the Release ELF to `artifacts/accelerator_tcp_server.elf` and record SHA-256 hashes for XSA, bit and ELF.

- [ ] **Step 4: Program the board and verify startup**

Run:

```powershell
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' FPGA/program_tcp_service.tcl
```

The script programs the bitstream, runs PS initialization, downloads the Release ELF and continues Cortex-A9 #0. UART must show:

```text
PHY address: 7
TCP server: 192.168.1.10:5001
DMA mode: interrupt
weights_ready=1 epoch=1
```

If startup reload fails, acceptance fails; do not force ready from XSCT.

- [ ] **Step 5: Run live network acceptance**

Run:

```powershell
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 queue-test
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 reload test_data/reference_weights.bin
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
```

Capture client and UART output in `board-results.txt`. Required evidence: all four compute classes pass, FIFO remains FIFO, at least one busy response is observed under saturation, reload increments epoch, post-reload selftest passes, disconnect/reconnect works, DMA MM2S/S2MM interrupt counts increase, and polling count remains zero.

- [ ] **Step 6: Document exact reproduction commands**

Update `software/baremetal/README.md` with cable requirements, PC IPv4 setup, Vivado build, Vitis build, XSCT programming, UART settings, server address, client commands and expected PASS lines.

- [ ] **Step 7: Run completion verification and inspect repository state**

Run:

```powershell
git diff --check
git status --short
git ls-files | rg "vitis_workspace|\.Xil|\.runs|\.cache"
```

Expected: no whitespace errors, only intended source/artifact/report changes, and no generated workspace files tracked.

- [ ] **Step 8: Commit verified deliverables**

```powershell
git add software/baremetal/README.md reports/tcp_service/build-results.txt reports/tcp_service/board-results.txt artifacts/system_wrapper_tcp_service.bit artifacts/system_wrapper_tcp_service.xsa artifacts/accelerator_tcp_server.elf
git commit -m "test: verify interrupt TCP accelerator on Z15"
```

- [ ] **Step 9: Push main only after every gate passes**

```powershell
git push origin main
```

Expected: remote `main` advances to the locally verified commit; no feature branch or pull request is created.
