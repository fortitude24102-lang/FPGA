# 验证与发布证据

`dma_batch/` 是当前正式 DMA/突发/批处理版本的证据集：

- `board-results.txt`：正式 Z15 串口验收日志。
- `legacy-comprehensive-final.txt`：AXI4-Lite 兼容性回归日志。
- `performance.md`：带口径说明的最终性能汇总。
- `software_build.txt`：Vitis Debug/Release 构建信息。
- `impl/`：时序、资源、DRC、布线状态和机器可读门禁指标。
- `rtl/`：综合级资源报告。
- `release-hashes.sha256`：正式 bit/XSA 发布哈希。

`tcp_service/` 保存千兆网、热加载、LCD/Web 演示版的构建、实板日志、发布哈希
和最新实现报告。该版本功能验收通过，但 `impl/gate_metrics.txt` 记录全局
WNS `-2.987 ns`，不属于时序收敛基线。

`reports/` 目录中的 `Z15_FPGA项目验收与测试报告_20260811_DMA最终版.docx`
是最终验收文档。基础模板位于 `docs/templates/`，原始任务文档位于
`docs/requirements/`。`lcd/utilization.rpt` 保存最终 LCD 状态面板的资源报告。

临时渲染目录、旧日期报告、ILA/实验报告和候选串口日志不属于正式证据，已
删除或由 `.gitignore` 排除。

新的候选实现报告由 `FPGA/rebuild_dma_batch.tcl` 写入被忽略的
`reports/candidate_dma_batch/`，不会覆盖本目录中的正式验收证据。
