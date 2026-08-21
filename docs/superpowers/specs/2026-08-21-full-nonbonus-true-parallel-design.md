# Z15 全部非加分项与三加速器真并行设计

日期：2026-08-21

状态：用户已批准架构，等待设计文档复核

目标平台：Z15 ZYNQ-7015（XC7Z015CLG485-2），Vivado/Vitis 2019.2

需求来源：`FPGA修改.docx`，并按用户要求额外纳入“三加速器真正并行”加分项

## 1. 目标与范围

本阶段在当前已通过板级验证的 AXI DMA、中断、TCP 服务、热更新和批处理工程上继续演进，完成 `FPGA修改.docx` 中除加分项外的全部要求，并把当前串行的 Pipeline 改造为 Tanimoto、GNN、ADMET 三个物理计算核真正并行运行。

### 1.1 必须完成

1. 保留 128-bit AXI DMA、HP0、Burst 和中断数据面。
2. Tanimoto、GNN、ADMET 拥有独立任务控制、输入缓冲和结果缓冲。
3. 三类独立任务能够异步启动并在三个计算核上同时运行。
4. Pipeline 在全部输入装载完成后，同周期启动三个计算核，并在三个完成标志都到达后组合结果。
5. 支持 Tanimoto 128、GNN 16/32、ADMET 64、Pipeline 8/16 批量。
6. 权重预加载、运行时热更新和 GNN/ADMET 双 Bank 原子切换。
7. 软件请求 FIFO 深度 8，支持 3 至 5 个 TCP 客户端并发。
8. 动态选择 50、100、150 MHz 加速器时钟。
9. ILA 捕获 DMA Burst、三个计算核 start/done 和并行重叠证据。
10. 四级超时、CPU fallback 通知、显式服务状态机和 10 秒看门狗。
11. XADC 温度/电压监控、HTTP 状态面板和板载 800×480 RGB LCD 状态页。
12. 完成 1000 次 Pipeline 稳定性、延迟抖动、CPU 占用、并发连接和 10 万分子/5 分钟验收。

### 1.2 明确不做

以下仍属于未纳入的加分项：

- 多 FPGA 级联。
- 量化、剪枝或模型算法变更。
- HIL 随机向量 CPU/FPGA 大规模 RMSE 对拍框架。
- LCD 电容触摸交互；本阶段 LCD 只承担状态显示。
- PetaLinux、Linux 驱动或 Linux 图形栈迁移。

### 1.3 兼容性要求

- 保留当前 `0x43C00000` 加速器控制地址和 AXI-Lite 兼容入口。
- 保留 TCP 端口 `5001` 和现有 16-byte 头部的基本布局。
- 保留已验证的参考权重和数值算法，不改变定点格式。
- 新设计未全部通过前，不覆盖当前稳定 bit/XSA/ELF。
- Vivado/Vitis 自动生成目录留在本机，但不提交 Git。

## 2. 方案选择

采用“单 AXI DMA + 共享 DDR 带宽调度 + 三个独立计算引擎”。

未采用三套 AXI DMA，因为它会明显增加 DMA、AXI、HP 端口、中断和软件驱动复杂度；现有单 DMA 已实测接近 1 GB/s，吞吐瓶颈不在 DMA 数量。未改用 PetaLinux，因为当前裸机 TCP 服务、PHY 补丁和中断路径均已验证，迁移不能直接提高计算并行度。

单 DMA 方案满足文档所述“独立 DMA 输入/输出通道或共享 DDR 带宽调度”中的后者。关键不是复制 DMA，而是取消单一后端串行状态机，让三套现有计算核在独立缓冲和控制器下同时工作。

## 3. 总体架构

```text
PS Ethernet / TCP 5001 / HTTP 80
                 |
        software request FIFO(8)
                 |
        AXI DMA 128-bit / HP0
                 |
        stream parser + dispatcher
          /          |          \
 Tanimoto queue   GNN queue   ADMET queue
 + ping-pong      + ping-pong + ping-pong
          \          |          /
      three independent engine controllers
          \          |          /
       completion scoreboard + result reorder
                 |
        AXI DMA S2MM / TCP reply

 Control/telemetry:
 AXI-Lite 100 MHz -> service registers / DFS / LCD snapshot / ILA probes
 XADC + clocks + queue + weights + errors -> HTTP JSON and RGB LCD
```

### 3.1 时钟域

- PS/AXI-Lite 控制域：固定 100 MHz。
- DMA/HP0 内存域：保留已验证的 125 MHz。
- 加速器计算域：由可动态重配置 Clocking Wizard 输出 50/100/150 MHz。
- LCD 像素域：独立固定 30 MHz。
- DMA 与加速器之间继续使用异步 AXIS FIFO。
- AXI-Lite 控制与动态计算域之间只通过同步器、握手和快照寄存器通信。

DFS 只允许在所有引擎空闲或被安全停止后执行。切换流程为：禁止接收新硬件任务、排空队列、复位计算域、重配置时钟、等待 `locked`、按新频率更新超时周期、释放复位、恢复 READY。

## 4. 三引擎真并行

### 4.1 独立引擎

新增三个独立适配层：

- `tanimoto_dma_engine`：管理 query/database 指纹双缓冲、共享 query 批量和结果 FIFO。
- `gnn_dma_engine`：管理 adjacency/features 双缓冲、GNN start/done、摘要或完整输出。
- `admet_dma_engine`：管理 descriptor 双缓冲、四模型预测和结果 FIFO。

每个引擎具有独立的 `task_valid/task_ready`、`payload_valid/payload_ready`、`busy/done/error` 和任务上下文。一个引擎忙时，另外两个引擎仍可接收和执行各自任务。

### 4.2 Dispatcher 与完成记分牌

流解析器检查批头、任务头、长度、flags、item_count 和 reserved 字段，然后按 task_id 把 payload 路由到对应引擎。每个批次最多 64 个任务，使用序号记分牌记录：

- job_id、user_tag、task_id、flags。
- 输入顺序和结果容量。
- 已装载、运行、完成、超时、fallback 状态。
- 对应引擎和输入/输出 Bank。

结果可以乱序完成，但 `dma_result_formatter` 按输入序号输出，保持现有协议和调用方行为稳定。摘要结果完成后立即复制到小型结果 FIFO；请求完整 GNN 输出时，在输出被安全读取前不复用该输出 Bank。

### 4.3 Pipeline 同周期启动

每个 Pipeline item 包含互相独立的三组输入：

1. Tanimoto query/database：64 words。
2. GNN adjacency/features：1679 words。
3. ADMET descriptor：20 words。

调度器先把三组输入写入三个引擎各自选定的非活动 Bank。三组 `load_done` 同时成立后，Pipeline coordinator 在同一个加速器时钟沿发出三路 `start`。三个引擎独立运行；coordinator 锁存三路结果和完成周期，在三路都完成后产生该 item 的 Pipeline 结果。

这会替换当前 `ST_PIPE_TANI -> ST_PIPE_GNN -> ST_PIPE_ADMET` 串行链。

### 4.4 批内重叠

GNN 和 Pipeline 批量采用 item 级 ping-pong：当前 Bank 计算时，另一个 Bank 装载下一 item。Tanimoto 继续使用共享 query 连续候选流；ADMET 以 64 item 为一批连续执行。这样批量收益来自减少 DMA/TCP 固定开销和装载/计算重叠，而不是复制 32 个 GNN 核。

## 5. 协议与批量

### 5.1 限制

- `MOL_DMA_MAX_ITEM_COUNT` 从 64 提升到 128。
- `MOL_TCP_SLOT_BYTES` 从 24 KiB 提升到 256 KiB。
- 软件 FIFO 深度仍为 8。
- DMA 单次传输上限仍为 2 MiB。
- 大缓冲区放在 PS DDR/BSS，不消耗 PL BRAM。

### 5.2 Payload 布局

| task | item_count | payload_words | 默认 result_words |
|---|---:|---:|---:|
| Tanimoto shared query | 1..128 | `32 + 32*N` | `N` |
| GNN | 1..32 | `1679*N` | `N` |
| ADMET | 1..64 | `20*N` | `4*N` |
| Pipeline | 1..16 | `1763*N` | `4*N` |
| Weight reload | 1 | `4538` | `1` |

GNN `FULL_GNN_OUTPUT` 返回 `3200*N` words。Pipeline `RETURN_INTERMEDIATE` 返回每 item 6 words；`FULL_GNN_OUTPUT` 返回每 item 3205 words。

### 5.3 TCP 头与保留字段

现有 16-byte TCP 头保持：magic/version/task_id/flags、payload_len、trace_id、batch_size。请求 flags 的未定义位必须为 0；响应保留 `RESPONSE/BUSY/ERROR/FALLBACK`。所有 padding/reserved 字段必须为 0，否则返回显式协议错误。

新增本地服务任务 `0xFD` 用于查询状态，不进入 DMA；`0xFE` 继续用于权重热更新。状态响应包含服务状态、队列深度、连接数、三引擎 busy 位、权重 epoch、当前频率、XADC、IRQ 计数、错误和 watchdog 信息。

## 6. 权重双缓冲与热更新

GNN 和四套 ADMET 模型各有 Bank A/B：

1. 上电把参考权重写入非活动 Bank。
2. 校验写入 word 数、顺序和校验值。
3. 第一次成功后把该 Bank 设为 active，进入 READY。
4. 热更新始终写 inactive Bank，正在运行的任务继续使用启动时锁存的 Bank。
5. 校验成功后递增 epoch，并原子切换“后续任务 active Bank”。
6. 校验失败不切换，旧 Bank 保持可用，服务返回 RELOAD 错误。

Bank 选择在任务启动时锁存，避免热更新与并行计算发生权重撕裂。

## 7. 超时、fallback 与恢复

### 7.1 四级超时

1. AXI-Lite 控制访问：100 us；失败最多重试 3 次。
2. PL 计算：每 item 2 ms；批任务总超时按 item_count 成比例计算并增加 DMA 保护时间。
3. TCP：请求帧或连接无进展 5 s 后关闭。
4. PS SCU Watchdog：10 s；主服务正常推进时喂狗。

### 7.2 Fallback

PL 计算超时后：

- 停止对应引擎并清理其活动 Bank。
- 当前响应设置 `ERROR|FALLBACK`，返回 task、item 和超时阶段。
- Python 主机客户端识别 FALLBACK 后调用 CPU 参考路径，并保留 trace_id。
- 服务状态记录 fallback_count；只要硬件能够恢复，后续请求不受影响。

连续恢复失败或 DMA/时钟无法重新锁定时进入 ERROR，拒绝计算请求，但仍允许状态查询和健康检查。

## 8. 服务状态机与 CPU 占用

服务状态固定为：

- `INIT`：初始化 DMA、GIC、网络、XADC、LCD、watchdog 和参考权重。
- `READY`：可接收请求。
- `BUSY`：至少一个引擎运行或请求排队。
- `RELOAD`：写入非活动权重 Bank；已有任务可按锁存 Bank 完成。
- `ERROR`：不可安全继续计算；保留诊断接口。

DMA 与 Ethernet 使用中断推进。主循环没有网络、队列、定时任务时执行 `WFI`，用全局计时器统计 busy/idle 周期。CPU 占用率定义为测量窗口内非 WFI 周期占比，并在 UART、状态 API 和验收报告中给出；满负载批处理目标 `<5%`。

## 9. HTTP 状态面板

裸机 lwIP 同时监听：

- TCP 加速服务：`192.168.1.10:5001`。
- HTTP：`192.168.1.10:80`。

HTTP 服务不引入第三方 Web 框架，只实现本项目需要的固定路由：

- `/`：静态单页状态面板。
- `/api/fpga/health`：JSON 健康状态。
- `/api/fpga/benchmark`：最近一次基准结果；带运行参数时启动受控基准任务。

面板显示三引擎状态、当前频率、队列、连接、权重 epoch、DMA/IRQ、温度、电压、watchdog、错误计数、批处理吞吐、延迟和加速比。页面定时拉取 JSON，不使用外部 CDN，断网直连时仍能显示。

## 10. 800×480 RGB LCD

Z15 底板 J20 为与 ATK-MD0430R 对应的 40-pin RGB TFTLCD 接口。使用参数：

- RGB888，24-bit 数据。
- 800×480 有效显示区。
- 30 MHz 像素时钟。
- 典型水平总周期 928：HSYNC 3、back porch 40、active 800、front porch 48，其余用于边界修正。
- 典型垂直总周期 525：VSYNC 3、back porch 32、active 480、front porch 13。
- 5V 模块供电，PL IO 为 3.3V LVTTL。

LCD 不使用 DDR framebuffer，也不占用第二套 DMA。新增轻量级时序/字符渲染器，在像素域根据状态快照生成固定仪表盘：

- 顶栏：MolRecommender FPGA Accelerator。
- 服务状态和当前 50/100/150 MHz。
- 三个引擎独立 READY/BUSY/DONE/ERROR。
- 队列深度、连接数、权重 epoch。
- 温度、VCCINT、VCCAUX。
- 最近批量吞吐、Pipeline 延迟和 CPU 占用。
- 错误和 watchdog 状态。

不用 PL LED。触摸 IIC/INT/RST 暂不启用。LCD RGB 引脚与 HDMI IN 数据路径共享，因此本构建不同时启用 HDMI IN。

## 11. XADC 与健康监控

使用 Zynq XADC PS 驱动读取芯片内部温度、VCCINT 和 VCCAUX，不要求外接 VP/VN。每秒采样并进行短窗口平均，更新健康快照。异常值写入状态 API、LCD 和 UART；严重温度或时钟失锁禁止启动新计算任务，但不立即破坏当前诊断连接。

## 12. ILA 与可观测性

提供 Debug 和 Release 两种可重复构建：

- Debug 构建加入小型 ILA，捕获 MM2S/S2MM `TVALID/TREADY/TLAST/TKEEP`、三个引擎 start/busy/done、Pipeline 同周期启动、active Bank、DFS 状态和错误。
- Release 构建移除 ILA，保留相同功能和寄存器，避免影响最终资源与时序。

Debug bitstream 生成 `.ltx`，上板保存至少三类证据：DMA Burst、三引擎独立任务重叠、Pipeline 三路同周期 start。捕获结果和资源差异写入报告。

## 13. 验收标准

### 13.1 功能

- 所有原有 RTL/软件测试继续通过。
- Tanimoto 128、GNN 16/32、ADMET 64、Pipeline 8/16 数值正确。
- 三类独立任务在 ILA 中出现计算时间重叠。
- Pipeline 三路 start 在同一加速器时钟周期。
- 热更新期间旧任务使用旧 Bank，新任务在原子切换后使用新 Bank。
- 状态机、reserved 校验、四级超时、fallback 和 watchdog 可重复触发与恢复。
- LCD 与 HTTP 面板显示一致的健康快照。

### 13.2 性能与稳定性

- 1000 次 Pipeline 全部成功，计算延迟抖动不超过 ±5 us。
- 1000 次权重不变测试结果一致。
- 5 个 TCP 客户端并发，FIFO 深度 8，无静默丢请求。
- 10 万个 Tanimoto 候选分子使用 128 批量完成时间不超过 5 分钟。
- DMA 仍为中断模式，polling transfer count 为 0。
- 满负载批处理 CPU 占用低于 5%。
- 50/100/150 MHz 三档均可运行并返回正确结果。

### 13.3 实现质量

- Vivado `validate_bd_design` 无 Error/Critical Warning。
- DRC Error = 0，route status 正常。
- 50/100/125/150/30 MHz 相关时钟 WNS、WHS 均不为负。
- LUT、FF、BRAM、DSP 不超过 XC7Z015 资源。
- 最终性能报告使用板上实测端到端时间，不用纯 RTL 周期替代。

## 14. 测试策略

坚持测试先行：每项生产代码前先加入失败测试。

1. Python/C 协议测试：新批量上限、payload/result 形状、reserved、状态任务、HTTP JSON 和 fallback。
2. SystemVerilog 单元测试：三引擎 dispatcher、记分牌、乱序完成重排、Pipeline 同周期 start、批内 ping-pong、权重 Bank 原子切换、超时和 DFS 停机握手。
3. 现有全量 RTL 回归。
4. IP 打包与 Block Design 自动检查。
5. Vivado 综合、实现、时序、DRC 和资源检查。
6. Vitis 固件构建和主机客户端测试。
7. JTAG 上板：功能、ILA、LCD、HTTP、并发、1000 Pipeline、10 万分子、CPU、XADC、watchdog、DFS。

所有验收输出保存到 `reports/`，并更新最终 Word 验收报告。只有 Release 构建、固件和全部板测通过后，才替换 `artifacts/` 中的稳定交付物。

## 15. 交付物

- 真并行 RTL、协议生成物和 SystemVerilog 测试。
- 可重复重建 Block Design/IP 的 Tcl。
- Debug bit/XSA/LTX 与 Release bit/XSA。
- 裸机 TCP/HTTP/LCD/XADC/watchdog/DFS 固件。
- Python 主机客户端、并发/性能/fallback 测试工具。
- 板级 UART、ILA、HTTP、LCD 和性能证据。
- 更新后的架构、部署、使用说明和 Word 验收报告。

## 16. 风险控制

- 150 MHz 时序风险：先以测试锁定功能，再对 GNN 长路径进行寄存器切分；不以降低验收频率掩盖失败。
- 双 Bank 资源风险：优先推断 BRAM；综合后逐层核对，不允许 LUT RAM 无控制膨胀。
- 大 TCP 缓冲风险：缓冲放 PS DDR/BSS，检查链接脚本和栈/堆边界。
- LCD IO 风险：严格使用 Z15 RGB LCD 专用引脚，不与 HDMI IN 同时启用，插拔前断电。
- 回归风险：始终保留已验证版本，新的 stable artifacts 仅在全部验收通过后原子替换。
