# Z15 DMA、突发传输与批处理最终验收结果

日期：2026-08-11

器件：XC7Z015CLG485-2

工具：Vivado/Vitis 2019.2

数据通路：PS DDR → AXI DMA Simple Mode → 128-bit AXIS → 64 项混合任务队列；DMA 存储侧经 HP0、150 MHz 运行。

## 结论

DMA、突发传输、批处理、错误恢复和旧 AXI-Lite 接口兼容性全部通过。所有强制性能目标均达到。正式 UART 证据见 `board-results.txt`，旧接口综合自测证据见 `legacy-comprehensive-final.txt`。

## 板级性能

| 项目 | 实测 | 目标 | 结果 |
|---|---:|---:|---|
| MM2S，2 MiB | 1198.37 MB/s | ≥500 MB/s | PASS |
| S2MM，2 MiB | 1199.74 MB/s | ≥500 MB/s | PASS |
| 单次共享查询 Tanimoto，N64 | 32 µs，20.62× | ≥20× | PASS |
| 共享查询 Tanimoto，8×N64，共 512 个结果 | 202 µs，26.13× | 吞吐证据 | PASS |
| Tanimoto 纯核心 | 5 周期，0.05 µs，120.00× | >50× | PASS |
| GNN summary/full | 796 µs，33.84× | >10× | PASS |
| ADMET N64 | 97 µs，21.11× | >20× | PASS |
| Pipeline 三种结果模式 | 1087 µs，37.28× | >30× | PASS |
| 混合 0/1/2/3 任务批 | 580 µs，46.58× | 信息项 | PASS |

`PERF` 时间从 DMA 传输函数进入开始，到接收缓冲失效并定位完整响应结束；包含 DMA 配置、数据搬运、队列和核心执行，不包含请求包构造及随后逐记录的应用层数值核验。单次 N64 是独立 DMA 请求，没有使用 8×N64 批量摊销结果代替强制目标。

Tanimoto 纯核心的 5 周期来自 RTL `tb_tanimoto_latency` 在 100 MHz 下的直接延迟测量。任务记录中的 `post_payload_cycles` 只表示最后一个载荷字之后的队列尾延迟，不作为每个分子计算延迟。

## Tanimoto 优化剖析

首个 DMA 批处理版本为 427 µs、12.36×，其中 TX 缓存刷新 157 µs、引擎 256 µs。加入独立 1 MiB 非缓存 TX 区和 AXIS 前端无气泡 refill 后，8×N64 降至 232 µs。最终版进一步在 Tanimoto 核计算前一个候选时并行装载下一个候选，隐藏候选间核心等待周期：

| 阶段 | 单次 N64 | 8×N64 |
|---|---:|---:|
| TX flush | 0 µs | 0 µs |
| RX flush | 0 µs | 2 µs |
| DMA + 队列 + 核心 | 29 µs | 189 µs |
| RX invalidate | 0 µs | 2 µs |
| 响应边界解析 | 1 µs | 8 µs |
| 总计（计时取整） | 32 µs | 202 µs |

## 功能与可靠性

- Tanimoto 三组参考向量、单次共享查询 N64、8×N64、GNN summary/full、ADMET N64、Pipeline default/intermediate/full 全部数值通过。
- 0/1/2/3 混合任务顺序通过。
- continue/stop-on-error、软件超时、DMA reset recovery 通过。
- 连续 1000 批压力测试通过，确定性哈希 `0x96FF4BF5`。
- 最终回归：23 个 RTL testbench、1 个协议漂移检查、7 个主机端布局/边界测试全部通过。
- 旧 AXI-Lite 综合自测在 DMA 版本上输出 `ALL COMPREHENSIVE SELF-TESTS PASSED`。

## 实现门禁

| 指标 | 实测 | 结果 |
|---|---:|---|
| 100 MHz WNS / WHS | +0.012 ns / +0.010 ns | PASS |
| 150 MHz WNS / WHS | +0.460 ns / +0.060 ns | PASS |
| 未布线网络 | 0 | PASS |
| DRC Error / Methodology Error | 0 / 0 | PASS |
| LUT | 31,133 / 46,200 | PASS |
| FF | 16,707 / 92,400 | PASS |
| BRAM | 21 / 95 | PASS |
| DSP48 | 78 / 160，且 ≥70 项目门限 | PASS |

## 正式产物

- `artifacts/system_wrapper_dma_batch.bit`

  SHA-256: `81EF25EEAA2ADB1783A28EAADCF305367E00756319CCEB973B5AD308FF9ABC3E`
- `artifacts/system_wrapper_dma_batch.xsa`

  SHA-256: `736397FA243D1A30CBDAD151C1C3CFA19A0B0D1168BA68FE027A55ABFDEB6A61`
- `vitis_workspace/accelerator_dma_batch/Release/accelerator_dma_batch.elf`
  SHA-256: `7CDC19012656F94D0CA47F8E52F6698FA5D2A4424EF21892A5CCBCC4FDA4B3CE`

候选与正式 bit/XSA 哈希逐项一致；此前稳定的 `system_wrapper_custom_bridge_ila.*` 未被覆盖。
