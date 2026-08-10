# MolRecommender FPGA DMA、突发传输与通用任务队列设计

日期：2026-08-10

状态：已批准架构方向，等待书面规格复核

目标平台：Z15 ZYNQ-7015，XC7Z015CLG485-2，Vivado/Vitis 2019.2

## 1. 背景

现有加速器已经完成 Tanimoto、GNN、ADMET 与 Pipeline 四类任务，并在 100 MHz 下通过 RTL、实现和板级综合自检。当前数据通路仍以 PS `M_AXI_GP0` 访问 `0x43C00000` 的 AXI-Lite 寄存器窗口：GNN 的 1600 个输入字和 3200 个输出字均由 Cortex-A9 使用 `Xil_Out32`/`Xil_In32` 逐字搬运。该方式功能正确，但 CPU 参与度高，无法利用 DDR 突发带宽，也无法一次提交混合任务批次。

本设计在保留现有 AXI-Lite 接口的前提下，增加 AXI DMA、HP0 高性能端口、128-bit AXI-Stream 数据面和软件管理的通用任务队列。队列支持 task 0/1/2/3 混排，并面向 MolRecommender 的“分析—生成—校验—决策”流程提供稳定的硬件作业接口。

## 2. 目标与非目标

### 2.1 目标

1. 使用 AXI DMA Simple Mode 在 DDR 与 PL 之间传输批次，数据面不再逐字访问 AXI-Lite。
2. 通过 PS `S_AXI_HP0` 发起 AXI 突发，DMA 内存侧运行在 150 MHz。
3. 使用 128-bit AXI-Stream 传送任务和结果，计算核心继续运行在 100 MHz。
4. 一个批次最多包含 64 个任务，task 0/1/2/3 可以任意混排。
5. 支持 Tanimoto 共享查询批模式和 ADMET 多样本模式，减少小任务的固定传输开销。
6. GNN 与 ADMET 权重在批次之间复用，不重复计入每个样本。
7. 保持现有寄存器映射、旧 Vitis 自测和 9 个 RTL testbench 的兼容性。
8. 提供逐任务状态、错误码、结果长度和硬件周期计数。
9. 最终实现满足全部时钟约束、DRC 0 Error，并不超过 XC7Z015 资源上限。

### 2.2 非目标

1. 第一版不启用 AXI DMA Scatter-Gather 描述符引擎。
2. 第一版不让加速器直接作为 AXI Master 访问任意 DDR 地址。
3. 第一版不通过 DMA 更新 GNN/ADMET 权重；权重仍通过现有 AXI-Lite 配置并长期复用。
4. 第一版不复制计算核心，不改变已通过验收的 Tanimoto、GNN、ADMET 数值算法。
5. 第一版不实现 Linux 驱动，只提供 standalone Vitis 驱动与板级验证程序。

## 3. 方案选择

### 3.1 采用方案

采用“AXI DMA Simple Mode + 流内任务描述符 + 软件管理 DDR 队列”。PS 为每个批次构造连续发送缓冲区和接收缓冲区；一次启动 S2MM 和 MM2S；PL 在数据流内解析任务描述符、执行任务并返回结果。

### 3.2 未采用方案

- Scatter-Gather DMA：可以让 DMA 自行遍历 DDR 描述符，但增加资源、缓存一致性和异常恢复复杂度，当前批次最大 64 个任务不需要该能力。
- 自定义 AXI Master：灵活性最高，但需要自行验证 AXI4 突发、乱序响应、超时和 DDR 地址安全，风险高于本项目收益。

## 4. 总体架构

```text
Cortex-A9 / Vitis
  ├─ legacy control: M_AXI_GP0 -> custom AXI3-to-AXI-Lite bridge -> accelerator registers
  ├─ DMA control:    M_AXI_GP1 -> custom AXI3-to-AXI-Lite bridge -> AXI DMA S_AXI_LITE
  └─ DDR buffers
       ▲                                              │
       │ S2MM                                         │ MM2S
       │                                              ▼
  PS S_AXI_HP0 <- AXI SmartConnect <- AXI DMA 64-bit memory map
                                      │
                         128-bit AXI-Stream, 100 MHz
                                      │
                 input FIFO -> task parser/scheduler
                                      │
                  Tanimoto / GNN / ADMET / Pipeline
                                      │
                         result formatter -> output FIFO
```

控制面和数据面分离。旧 `M_AXI_GP0` 路径不改动，避免再次引入已解决的 AXI3/AXI-Lite访问问题。DMA 的 AXI-Lite 控制单独使用 `M_AXI_GP1` 和第二个自定义协议桥。DMA 内存端通过 SmartConnect 汇聚 MM2S、S2MM 两个 AXI Master，并连接 PS `S_AXI_HP0`。

## 5. 时钟、总线与 Block Design

### 5.1 时钟域

- `FCLK_CLK0 = 100 MHz`：加速器、AXI-Lite 控制、AXI-Stream、FIFO 流侧。
- `FCLK_CLK1 = 150 MHz`：AXI DMA 内存映射侧、HP0 和数据 SmartConnect。
- AXI DMA启用异步时钟配置，内部完成内存侧与流侧跨时钟。
- 两个时钟域分别使用 `proc_sys_reset` 产生同步释放复位。

### 5.2 AXI DMA 配置

- Direct Register/Simple Mode。
- MM2S 和 S2MM 均启用。
- Scatter-Gather 关闭。
- Memory Map Data Width：64 bit。
- Stream Data Width：128 bit。
- Length Width：23 bit。
- Burst Type：INCR；HP0 AXI3 侧由 SmartConnect 转换和拆分为合法突发。
- DRE 关闭；软件保证缓冲区 64-byte 对齐，协议有效长度为 4-byte 整数倍；最后一个 128-bit beat 可使用部分 `TKEEP`。
- MM2S/S2MM 中断接入 `IRQ_F2P`，同时保留轮询模式用于早期调试。

### 5.3 FIFO

- 输入 AXIS Data FIFO：512 个 128-bit beat，即 8192 byte，可缓存一个最大 Pipeline 输入任务。
- 输出 AXIS Data FIFO：256 个 128-bit beat，用于隔离 S2MM 短暂停顿。
- FIFO 必须完整传递 `TKEEP`、`TLAST` 和 `TVALID/TREADY` 背压。

### 5.4 调试资源

最终构建移除当前大型 AXI System ILA，释放约 3156 LUT、12 RAMB36 和 5166 FF。另保留可选 debug Tcl，在需要时插入小型 AXIS ILA；debug bitstream 不作为最终性能验收产物。

## 6. 批次与任务协议

### 6.1 通用规则

- 字节序：little-endian。
- 逻辑字段以 32-bit word 定义。
- AXI-Stream 每个 128-bit beat 按低位到高位承载 4 个连续 word。
- `TKEEP` 仅允许最后一个 beat 非全 1。
- 一个 DMA MM2S 包对应一个完整批次，`TLAST` 只在批次最后一个 beat 置位。
- 批次最大 64 个任务；发送和接收缓冲区各自最大 2 MiB。

### 6.2 输入批次头，固定 8 words

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | magic | `0x4D4F4C51`，ASCII `MOLQ` |
| 1 | version/header_words | 低 16 bit 为版本 1，高 16 bit 为 8 |
| 2 | batch_id | 软件生成的批次编号 |
| 3 | task_count | 1 到 64 |
| 4 | total_words | 包含批次头的实际输入 word 数 |
| 5 | batch_flags | bit0=`CONTINUE_ON_TASK_ERROR`，其余必须为 0 |
| 6 | max_result_words | 软件已分配的接收容量 |
| 7 | reserved | 必须为 0 |

### 6.3 任务头，固定 8 words

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | job_id | 批次内由软件分配，必须唯一 |
| 1 | task_and_flags | bits[7:0] task_id；bits[31:8] task flags |
| 2 | payload_words | 紧随任务头的 payload word 数 |
| 3 | result_capacity_words | 软件为本任务预留的最大结果 payload word 数，不含 8-word 结果头 |
| 4 | item_count | 任务内部的样本数；范围 1 到 64 |
| 5 | user_tag | 原样返回，供多智能体/后端关联请求 |
| 6 | timeout_cycles | 0 表示使用硬件默认值 |
| 7 | reserved | 必须为 0 |

### 6.4 Task flags

- bit8 `FULL_GNN_OUTPUT`：返回完整 3200-word GNN 输出；为 0 时只返回 `output[0]`。
- bit9 `RETURN_INTERMEDIATE`：Pipeline 返回 Tanimoto、GNN摘要和 ADMET 结果。
- bit10 `SHARED_QUERY`：Tanimoto payload 使用一个查询指纹配多个候选指纹。
- 其余位必须为 0；出现未知 flag 时该任务返回协议错误。

### 6.5 输入 payload

| task_id | 工作负载 | item_count | payload_words |
|---:|---|---:|---:|
| 0 | Tanimoto pair | 1 | 64 |
| 0 | Tanimoto shared-query | N | `32 + 32*N` |
| 1 | GNN 50x64x128 | 必须为 1 | `79 + 1600 = 1679` |
| 2 | ADMET 20->10->1 四模型 | N | `20*N` |
| 3 | Pipeline | 必须为 1 | `64 + 79 + 1600 + 20 = 1763` |

GNN payload 顺序为 adjacency 79 words、features 1600 words。Pipeline 顺序为 query 32、database 32、adjacency 79、features 1600、descriptor 20。

### 6.6 输出批次头，固定 8 words

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | magic | `0x4D4F4C52`，ASCII `MOLR` |
| 1 | version/header_words | 版本 1，头长 8 |
| 2 | batch_id | 与输入一致 |
| 3 | expected_task_count | 来自输入批次头的 task_count |
| 4 | header_status | 输入批次头检查通过时为 0 |
| 5 | output_capacity_words | 来自输入批次头的 max_result_words，包含所有输出头和 trailer |
| 6 | output_flags | 版本 1 固定为 0 |
| 7 | reserved | 0 |

### 6.7 任务结果头，固定 8 words

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | job_id | 输入 job_id |
| 1 | task_and_status | bits[7:0] task_id；bits[31:8] status |
| 2 | result_words | 紧随结果头的有效 payload words |
| 3 | compute_cycles_lo | 64-bit 周期计数低 32 bit |
| 4 | compute_cycles_hi | 64-bit 周期计数高 32 bit |
| 5 | item_count | 实际处理样本数 |
| 6 | user_tag | 输入 user_tag |
| 7 | detail | 任务级错误细节；成功时为 0 |

### 6.8 结果 payload

- task 0：每个候选返回 1 个 Q16.16 word，共 `item_count` words。
- task 1：摘要模式返回 1 word；完整模式返回 3200 words。
- task 2：每个样本返回四个 Q8.8 结果，共 `4*item_count` words。
- task 3：默认返回最终 ADMET 四结果；`RETURN_INTERMEDIATE` 时返回 Tanimoto 1 word、GNN摘要 1 word、ADMET 4 words；同时设置 `FULL_GNN_OUTPUT` 时返回 Tanimoto 1 word、GNN 3200 words、ADMET 4 words。

### 6.9 输出批次 trailer，固定 8 words

最终统计只能在所有任务完成后确定，因此放在数据流末尾；`TLAST` 置于 trailer 的最后一个 beat。

| Word | 字段 | 说明 |
|---:|---|---|
| 0 | magic | `0x4D4F4C45`，ASCII `MOLE` |
| 1 | batch_id | 与输入一致 |
| 2 | completed_count | 已产生结果记录的任务数 |
| 3 | error_count | 非成功任务数 |
| 4 | total_result_words | 从输出批次头到 trailer 结尾的实际 word 数 |
| 5 | batch_status | 0 成功，非 0 表示批次级错误 |
| 6 | first_error_job_id | 无任务错误时为 `0xFFFFFFFF` |
| 7 | detail | 批次级错误细节，成功时为 0 |

## 7. RTL 模块边界

### 7.1 `dma_task_queue_frontend`

职责：接收 128-bit AXI-Stream、检查批次头和任务头、拆分 word、计算预期长度、向任务装载器发出标准化命令。它不包含具体算法逻辑。

### 7.2 `dma_task_loader`

职责：依据 task_id 将 payload 写入现有 query/database、adjacency、feature 和 descriptor 存储；task 0 共享查询模式走专用流式 Tanimoto 路径，避免将每个候选重复写入寄存器。

### 7.3 `dma_task_scheduler`

职责：保持每批最多一个计算任务处于执行态；产生原有 `start`；等待 `valid`；实施硬件超时；生成任务级状态。输入 FIFO 可以在计算期间缓存下一任务，但第一版不并行执行两个计算任务。

### 7.4 `dma_result_formatter`

职责：读取计算结果、插入输出批次头、任务结果头和最终批次 trailer、打包为 128-bit AXI-Stream，并在 trailer 末尾正确产生 `TKEEP`、`TLAST`。下游背压不能丢失或重复 word。

### 7.5 `tanimoto_stream_batch`

职责：在 `SHARED_QUERY` 模式下缓存一份 1024-bit 查询指纹，对连续候选指纹进行流式 popcount/倒数查找运算，按候选顺序输出 Q16.16 结果。该模块复用现有定点算法和倒数表，不改变数值口径。

### 7.6 顶层兼容

`generator_accelerator_top` 增加 `s_axis_job_*` 和 `m_axis_result_*` 接口，并实例化上述模块。原 AXI-Lite寄存器路径、地址映射和单任务状态机继续保留。为避免两条路径同时驱动计算核，顶层增加所有权仲裁：DMA 批次执行期间拒绝新的 AXI-Lite start 并置 legacy error；legacy 任务执行期间输入 DMA 保持背压。

## 8. 软件设计

### 8.1 驱动分层

- `mol_dma_protocol.h`：协议常量、结构、flag、状态码。
- `mol_dma_queue.c/.h`：批次构造、长度计算、对齐、DMA 启停、缓存维护和结果解析。
- `accelerator.c/.h`：保留旧 API；增加权重配置和 legacy 兼容调用。
- `main_dma_batch.c`：板级功能、错误注入和性能测试。

### 8.2 DMA 调用顺序

1. 构造 64-byte 对齐的 TX/RX 缓冲区。
2. 根据任务及 flag 精确计算最大结果长度。
3. `Xil_DCacheFlushRange(TX)`。
4. `Xil_DCacheInvalidateRange(RX)`。
5. 先启动 S2MM，再启动 MM2S。
6. 使用中断等待两个通道完成；调试模式允许轮询。
7. 再次 invalidate RX，检查 `MOLR`、逐任务结果、`MOLE` trailer、batch_id、长度、任务数和状态。
8. 将 job_id/user_tag 映射回 MolRecommender 上层请求。

### 8.3 中断与恢复

- MM2S、S2MM 分别接入 GIC。
- ISR 只记录完成或错误位，不解析结果。
- DMA 错误时执行通道 reset，并清空软件队列；超时后不得复用未确认的 RX 内容。
- 批次级错误必须返回明确原因或由软件报告 DMA 失败，不得静默重试。

## 9. 错误处理

### 9.1 任务级错误

以下错误终止当前任务。若 `CONTINUE_ON_TASK_ERROR=1`，解析器按 `payload_words` 排空当前 payload 后继续；否则生成当前任务错误结果和批次 trailer 后终止批次：

- 不支持的 task_id。
- 未知 task flag。
- item_count 超范围。
- payload_words 与 task/item_count 不一致。
- result_capacity_words 不足。
- 计算超时。

DMA 批次执行期间收到 legacy start 不改变 DMA 批次；旧 AXI-Lite 状态寄存器置 `LEGACY_BUSY` 错误，软件必须等待批次结束后重试。

### 9.2 批次级错误

以下错误终止整个批次并排空输入到 TLAST：

- magic 或 version 错误。
- task_count 为 0 或大于 64。
- total_words 超过 2 MiB 或与实际 TLAST 不一致。
- TLAST 提前、缺失或 TKEEP 非法。
- 输出总容量小于所有结果头的最低需求。
- 内部协议状态机失配。

### 9.3 状态码

状态码固定并由 RTL与软件共享：`OK`、`BAD_MAGIC`、`BAD_VERSION`、`BAD_LENGTH`、`BAD_TASK`、`BAD_FLAGS`、`BAD_ITEM_COUNT`、`RESULT_OVERFLOW`、`TASK_TIMEOUT`、`LEGACY_BUSY`、`STREAM_TRUNCATED`、`INTERNAL_ERROR`。

## 10. 性能设计

### 10.1 传输重叠

输入 FIFO 可在当前任务计算期间接收下一任务，输出 FIFO 可在 S2MM 短暂背压时缓存结果。权重不随样本重复传输。软件每批只发起一次 MM2S 和一次 S2MM，消除逐寄存器函数调用开销。

### 10.2 Tanimoto 特殊处理

单个 pair 需要传输两份 1024-bit 指纹，受物理带宽限制，不能仅依靠 DMA 保证 50×。共享查询模式只传一次 query，并在 150 MHz、64-bit HP0 与 128-bit 流侧之间连续传送候选。验收性能以 64 个候选的共享查询批次为主，同时保留单 pair 功能测试。

### 10.3 预期验收指标

- 有效 DMA 单向带宽不低于 500 MB/s。
- 批次内 CPU 不执行 payload/result 的 `Xil_Out32`/`Xil_In32` 循环。
- GNN 含传输加速比大于 10×。
- ADMET 64 样本批处理含传输加速比大于 20×。
- Pipeline 含传输加速比大于 30×。
- Tanimoto 64 候选共享查询模式必须显著优于当前 AXI-Lite 路径，端到端加速比至少达到 20×；大于 50×作为扩展目标。若未达到 50×，必须报告 HP0 实测带宽与理论上限，不允许用纯计算周期替代端到端时间。原有纯计算指标仍必须保持大于 50×。

## 11. 资源与时序约束

当前最终设计已使用 78/80 DSP，因此 DMA扩展不得增加 DSP。移除大型 ILA 后，DMA、SmartConnect、FIFO 和队列 RTL 使用释放出的 LUT/BRAM预算。

验收要求：

- 100 MHz 加速器/流时钟 WNS >= 0、WHS >= 0。
- 150 MHz DMA/HP0 时钟 WNS >= 0、WHS >= 0。
- DRC Error = 0。
- DSP <= 80。
- Total LUT、FF、BRAM 不超过 XC7Z015 可用资源。
- 原有 Tanimoto `<5000 LUT/<2000 FF` 与 GNN `<20 BRAM/<50 DSP` 子模块约束继续满足。

如果 150 MHz 时钟无法闭合，允许将 DMA 内存侧降为 125 MHz；降频必须在性能报告中披露，且重新验证带宽和端到端目标。

## 12. 验证策略

### 12.1 RTL 单元测试

在实现 RTL 前先编写失败测试：

1. 单 task 0/1/2/3 的包解析与结果格式。
2. task 0 共享查询 N=1、2、64。
3. task 2 item_count=1、64。
4. 1、2、64 个混合任务的顺序与 job_id/user_tag 保持。
5. `TVALID/TREADY` 随机背压，确保不丢字、不重字。
6. 最后 beat 的 1/2/3/4 word `TKEEP`。
7. magic、version、flag、payload长度和 item_count 错误。
8. TLAST 提前、缺失和额外数据。
9. result_capacity不足。
10. 计算超时、legacy/DMA 互斥和批次恢复。

现有 9 个 testbench 必须保持通过。

### 12.2 Block Design 与实现

- `validate_bd_design` 无 Error/Critical Warning。
- 地址空间包含 accelerator legacy control、DMA control 和 HP0 DDR 数据路径。
- 综合确认 DMA 路径使用 AXI burst，不回退为 AXI-Lite。
- 实现后检查双时钟 timing summary、route status、utilization 和 DRC。

### 12.3 板级测试

1. 单任务结果与 legacy 路径逐字一致。
2. 一个包含 task 0/1/2/3 的混合批次。
3. 64任务压力批次和连续 1000 批次稳定性。
4. 缓存开启下的 flush/invalidate 正确性。
5. 任务级错误后继续处理。
6. DMA 错误/reset 后下一批恢复。
7. Tanimoto 64候选、ADMET 64样本、GNN 和 Pipeline 的端到端计时。
8. 输出 UART 性能表，包括字节数、总时间、有效带宽、每任务延迟和加速比。

## 13. 交付物

- 更新后的 RTL与封装 IP。
- 可重复重建 Block Design 的 Tcl 脚本。
- 新增 DMA/批处理 testbench 与回归脚本。
- Vitis DMA 队列驱动与综合自测 ELF。
- 通过时序的 bit、ltx（仅 debug 版）和含 bit 的 XSA。
- 板级功能日志、带宽报告、端到端性能报告和更新后的验收 Word。

## 14. 实施边界

实施按四个可独立验证的阶段进行：

1. 协议与纯 RTL 队列前端/结果后端。
2. Block Design 中的 HP0、DMA、时钟、FIFO 和中断。
3. Vitis DMA 驱动、缓存管理和混合批次测试。
4. 综合实现、上板、性能迭代和文档更新。

每个阶段都保留上一阶段可运行产物；最终产物只有在 RTL 回归、双时钟时序、DRC 和板级综合批次测试全部通过后才替换当前稳定 bit/XSA。
