# 方案三：中断、DMA 权重热重载与 TCP 服务设计

日期：2026-08-20
目标平台：Z15（XC7Z015）+ Vivado/Vitis 2019.2
软件环境：Standalone + lwIP raw API

## 1. 目标与范围

本设计落实《FPGA修改.docx》中本轮确认的三项改造：

1. AXI DMA 收发完成由轮询改为中断驱动，并保留有界超时保护。
2. 增加 `weights_ready` 状态和任务号 `0xFE`，实现 GNN、ADMET 权重的受控 DMA 热重载。
3. 增加 TCP 5001 服务，使用文档规定的 16 字节帧头、8 项 FIFO 和 busy/error 响应。

现有 128-bit AXI-Stream、16-beat burst、HP0、批处理协议和计算任务保持兼容。AXI4-Lite 继续只承担控制寄存器访问；数据、批任务和权重通过 AXI DMA 传输。

本轮不引入 FreeRTOS，不实现 LED、XADC/DFS、多 FPGA、Web 前端或新的 AI 算法。这些属于文档的扩展建议，不属于已确认的三项任务。

## 2. 总体数据流

```text
TCP 客户端
   │  16-byte header + payload
   ▼
lwIP raw TCP stream parser
   │  validate / assemble
   ▼
8-entry FIFO (FIFO order, fixed storage)
   │
   ▼
DMA batch builder ── MM2S interrupt ──> accelerator AXIS input
                                           │
                                           ▼
                                    compute / weight reload
                                           │
accelerator AXIS output ── S2MM interrupt ──┘
   │
   ▼
response encoder ──> TCP client
```

网络任务和本地综合自测共用同一套 DMA 执行函数与协议生成文件，避免出现两套含义不同的任务格式。

## 3. DMA 中断

Block Design 已将 AXI DMA 的 `mm2s_introut` 和 `s2mm_introut` 经 `xlconcat` 接到 PS `IRQ_F2P`。软件使用以下已生成中断号：

- MM2S：`XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR`（61）
- S2MM：`XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR`（62）

软件初始化 `XScuGic`，分别注册 MM2S/S2MM ISR。ISR 只完成三件事：读取并确认 DMA IRQ 状态、记录完成标志、记录错误标志。缓存维护、结果解析和 TCP 发送均在主循环中执行。

每次传输流程为：清标志、先启动 S2MM、再启动 MM2S、等待中断标志。等待函数有固定截止时间；超时或 DMA error 时复位 DMA 通道并返回错误。这里的循环只等待 ISR 标志并同时服务 lwIP，不读取 DMA busy 位作为正常完成条件。

## 4. 权重状态与 DMA 热重载

### 4.1 状态机

软件维护：

- `weights_ready`：当前完整权重集可用于计算。
- `weights_epoch`：每次完整装载成功后加一。
- `reload_in_progress`：防止重入并用于网络状态判断。

上电时 `weights_ready=0`。软件将内置参考权重打包成 `0xFE` DMA 任务并执行；收到成功结果后才设置 `weights_ready=1`。所有 GNN、ADMET、Pipeline 请求在未就绪时返回明确错误，Tanimoto 不依赖权重，可继续执行。

收到网络热重载请求时，先完整校验长度和帧格式，再设置 `weights_ready=0` 并串行执行。成功后递增 epoch 并恢复 ready；任何解析、DMA 或硬件错误均保持 `weights_ready=0`，禁止使用部分写入的权重。

### 4.2 `0xFE` 任务格式

在规范 JSON 中新增 `MOL_DMA_TASK_WEIGHT_RELOAD = 0xFE`，再由现有生成器同步生成 C/Verilog 常量。任务 `item_count=1`，payload 固定为 18,152 字节，按小端 signed Q8.8 打包，每个 32-bit word 放两个 `s16`：低 16 位先写，高 16 位后写。

权重排列顺序：

1. GNN：8,192 个 `s16`，地址 0..8191。
2. ADMET 模型 0..3，每个模型依次为：
   - layer 0：20×10 输入权重（200）
   - layer 1：10 个隐藏层偏置
   - layer 2：10×1 输出权重
   - layer 3：1 个输出偏置

总计 9,076 个 `s16`，即 4,538 个 32-bit word。成功响应含一个结果字 `weights_epoch`。

RTL 前端对任务号、固定 payload 长度、item count、flags 和结果容量进行校验。后端收到每个 32-bit word 后，用两个时钟分别写低/高 16 位权重，并对 AXI-Stream 施加反压。顶层只在 DMA 权重任务活跃时选择 DMA 配置写口；其他时间保留原 AXI4-Lite调试写口。任务队列串行执行，因此不允许热重载和计算并发。

## 5. TCP 5001 协议

### 5.1 16 字节帧头

所有多字节字段均为 little-endian：

| 偏移 | 长度 | 字段 | 约束 |
|---:|---:|---|---|
| 0 | 1 | magic | `0x5A` |
| 1 | 1 | version | `1` |
| 2 | 1 | task_id | `0x00..0x03` 或 `0xFE` |
| 3 | 1 | flags | 响应 bit0，busy bit1，error bit2，fallback bit3；请求高四位及响应位必须为 0 |
| 4 | 4 | payload_len | 负载字节数 |
| 8 | 4 | trace_id | 原样回传 |
| 12 | 4 | batch_size | 1..64，热重载固定为 1 |

TCP 是字节流，接收器必须同时处理拆包、粘包和零长度/异常连接。只有完整帧通过校验后才能入队。

### 5.2 计算负载

- Tanimoto，batch=1：64 个 u32，query 32 words + database 32 words。
- Tanimoto，batch=2..64：共享 query 32 words + N×32 database words。
- GNN，batch=1：1,679 个 u32。
- ADMET，batch=1..64：N×20 个 u32。
- Pipeline，batch=1：1,763 个 u32。
- Weight reload，batch=1：4,538 个 u32，排列见 4.2。

网络 v1 不暴露 full-GNN/intermediate 等扩展结果模式；原 DMA/UART 综合自测继续覆盖这些内部模式。

### 5.3 响应

响应复用请求的 task_id、trace_id 和 batch_size，并置 `flags.response=1`：

- Tanimoto：N 个结果字。
- GNN：1 个摘要结果字。
- ADMET：4×N 个结果字。
- Pipeline：4 个结果字。
- Weight reload：1 个 epoch 结果字。

错误响应设置 error；FIFO 已满时设置 busy。错误 payload 为两个 u32：稳定错误码和可选细节值，客户端不需要解析 UART 文本。

## 6. 8 项 FIFO 与连接管理

FIFO 固定为 8 项，严格先进先出。每项使用 24 KiB 静态空间，可容纳最大的 18,152-byte 权重帧；总存储 192 KiB，放在 DDR，不使用堆分配。

服务器最多维护 5 个 TCP 连接。一个连接可以连续提交多个完整帧；所有连接的请求进入同一个 8 项 FIFO，因此同一连接和跨连接响应都遵循全局入队顺序。队列项保存连接槽编号和 generation，而不是长期保存裸 `tcp_pcb*`，从而避免客户端断开后引用失效。只有 FIFO 已满时才立即返回 busy。

主循环每轮依次执行：

1. `xemacif_input()` 接收网络数据。
2. `sys_check_timeouts()` 维护 lwIP 定时器。
3. 若 DMA 空闲，从 FIFO 取一项执行。
4. 编码并发送响应；若连接已关闭则丢弃响应并安全释放队列项。

## 7. 以太网与 PHY

Vivado PS7 开启 GEM0：RGMII 使用 MIO16..27，MDIO/MDC 使用 MIO52..53。板卡原理图确认 PHY 为 YT8531C、地址 7。

网络默认参数：

- MAC：`02:00:00:00:70:15`
- IP：`192.168.1.10`
- Netmask：`255.255.255.0`
- Gateway：`192.168.1.1`
- TCP port：`5001`

Vitis 2019.2 lwIP 对未知 RGMII PHY 默认走 Marvell 初始化，不能直接用于 YT8531C。项目提供最小 PHY 兼容补丁：按标准 Clause 22 启动自协商，从标准能力寄存器判断 10/100/1000 速率，并由 PS GEM 设置对应时钟；RGMII 延时沿用开发板 strap 配置，不写 Marvell 私有页寄存器。补丁通过可重复脚本应用到 BSP 生成目录并进行内容校验，避免人工改生成文件。

## 8. 错误处理

至少定义并测试以下错误：坏 magic、坏 version、保留 flags 非零、未知 task、payload 长度错误、batch 越界、FIFO 满、weights not ready、reload failed、DMA timeout、DMA IRQ error、TCP send failure。

协议错误只影响当前帧；无法确定下一帧边界的连接直接关闭。DMA 错误执行通道复位；权重装载错误额外清除 ready。所有等待都有上限，不允许网络或加速器永久阻塞主循环。

## 9. 验证与验收

### 9.1 主机软件测试

- 16-byte header 编解码和大小端 golden vectors。
- TCP 拆包、粘包、坏帧、断连。
- 8 项 FIFO 顺序、满队列 busy、连接 generation 防悬空。
- 各任务 payload 长度和 batch 边界。
- 中断成功、DMA error、超时复位。
- 上电权重装载、成功热重载、长度错误、装载失败后 not-ready。

### 9.2 RTL 仿真

- `0xFE` 前端合法/非法格式。
- 4,538-word 流的反压和低/高半字写入顺序。
- GNN/ADMET 最后地址边界。
- reload 与计算任务 FIFO 串行化。
- reload 成功结果和错误状态。
- 原有 23 项 RTL/协议回归必须全部保持通过。

### 9.3 工具与上板

- 协议生成检查无漂移。
- Vivado synthesis、implementation、timing、DRC 和 bitstream 全部通过，WNS 必须为正。
- Vitis BSP/platform/application clean build 通过。
- 上板确认 PHY 地址 7、链路速率和 TCP 5001 可连接。
- PC 客户端依次验证 Tanimoto、GNN、ADMET、Pipeline、8 项 FIFO busy、`0xFE` 热重载和断线恢复。
- UART 输出中断计数、错误码、weights epoch、网络连接和测试摘要，最终给出明确 PASS/FAIL。

## 10. 交付物

- 更新后的 canonical DMA 协议 JSON、生成器和 C/Verilog 头文件。
- 支持 DMA 权重写入的 RTL、testbench 和回归脚本。
- 中断式 DMA 驱动、TCP server、网络协议和 YT8531C BSP 补丁。
- Vivado PS GEM0 配置脚本、Vitis 平台/应用生成脚本。
- PC 端 TCP 测试客户端、自动测试和操作说明。
- 新 bitstream/XSA/ELF、构建及上板验证报告。
