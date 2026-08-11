# 项目目录与发布边界

本项目采用“可复现源与正式证据提交、工具生成状态留在本地”的组织方式。
Vivado/Vitis 的工作目录保持原位，避免破坏当前可打开、可继续构建的工程；
GitHub 仓库只保存复现设计和核验最终结果所需的文件。

## 受版本控制的目录

- `rtl/`：综合源。包括 Tanimoto、GNN、ADMET、流水线、DMA 数据面与
  AXI4-Lite 控制面。
- `protocol/`：DMA 协议规范和由规范生成的常量，修改协议时应先改这里。
- `sim/`：RTL testbench、回归入口与协议一致性测试；`sim/build/` 被忽略。
- `software/`：PS 端 Standalone 源、Vitis 创建/重建脚本和主机单元测试。
- `FPGA/`：Vivado 工程入口、Block Design、IP 配置 XCI、实现/编程 Tcl；
  cache、runs、hw、sim 和生成的 BD 输出不提交。
- `ip_repo/`：自定义 IP 的可复现打包源。
- `constraints/`：工程级时序约束。与自定义 IP 绑定的板级约束位于
  `ip_repo/generator_accelerator_1_0/src/`。
- `artifacts/`：只提交已通过门禁和上板验收的正式 bit/XSA。
- `reports/`：只提交正式实现报告、构建证据、实板日志、性能结果和最终 Word。
- `docs/requirements/`：原始项目任务文档。
- `docs/templates/`：最终报告生成所依赖的基础模板。
- `docs/superpowers/`：经确认的设计说明和执行计划。
- `asm/`、`test_data/`：Python 基准和确定性测试数据。
- `tools/`：协议生成、文档检查、PDF 导出和安全整理脚本。

## 仅保留在本地的目录

- `.Xil/`、`FPGA/.Xil/`：Vivado 会话状态。
- `FPGA/FPGA.cache/`、`FPGA/FPGA.hw/`、`FPGA/FPGA.runs/`、
  `FPGA/FPGA.sim/`、`FPGA/FPGA.ip_user_files/`：Vivado 生成结果。
- `FPGA/FPGA.srcs/sources_1/bd/system/` 下的 `hdl/`、`ip/`、`ipshared/`、
  `sim/`、`synth/`、`ui/`、`hw_handoff/`：由 `system.bd` 再生成的内容。
- `vitis_workspace/`：Vitis 平台、BSP、Debug/Release 应用和 ELF。
- `artifacts/candidate_dma_batch/`：重建脚本产生的待验收候选物。
- `reports/candidate_dma_batch/`：候选实现的时序、资源和门禁报告。
- `_local/archive/`：整理前的历史、调试、ILA、旧报告与一次性脚本，按原相对
  路径保存，便于本机恢复。

## 本地归档工具

预览将被归档的已知历史文件：

```powershell
& D:\FPGA\tools\organize_local_workspace.ps1
```

核对输出后应用：

```powershell
& D:\FPGA\tools\organize_local_workspace.ps1 -Apply
```

脚本拒绝移动 Git 已跟踪内容、正式 bit/XSA、正式板测日志和最终 Word；目标
已存在时也会停止，不会覆盖本地归档。
