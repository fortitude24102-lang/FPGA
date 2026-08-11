# FPGA 项目目录整理与 GitHub 发布设计

## 目标

在不删除、不迁移 Vivado/Vitis 正在使用的生成目录前提下，整理 `D:\FPGA` 的源码、正式产物、报告与本地历史文件；建立明确的 Git 上传边界，并把可复现、可验收的项目内容发布到 `fortitude24102-lang/FPGA`。

## 已确认原则

1. 保留 `FPGA/FPGA.*`、`.Xil/` 和 `vitis_workspace/` 等工具生成内容的本地文件，不执行删除。
2. Vivado/Vitis 缓存、运行目录、临时工作区和本地归档不提交 GitHub。
3. 不移动会影响 `.xpr`、`.bd`、Vitis platform/domain 或现有 Tcl 绝对/相对路径的工具目录。
4. GitHub 保留可重建源码、工程入口、正式 bit/XSA、最终板测证据、验收报告和复现说明。
5. 已存在的正式 DMA 交付物、板测日志及最终 Word 报告不得被历史版本覆盖。

## 目标目录职责

| 目录 | 内容 | GitHub |
|---|---|---|
| `rtl/` | 可综合 RTL 与协议头 | 提交 |
| `sim/` | SystemVerilog testbench、协议测试和回归入口 | 提交；忽略 `sim/build/` |
| `software/` | 裸机驱动、应用、Vitis 重建脚本和主机测试 | 提交；忽略生成 workspace |
| `FPGA/` | Vivado `.xpr/.bd`、必要 Tcl 和工程入口 | 提交入口；忽略 cache/runs/generated BD products |
| `ip_repo/` | 自定义 IP 源码、组件描述与 xgui | 提交 |
| `constraints/` | 时序约束和 Z15 板级约束 | 提交 |
| `protocol/` | DMA 协议单一事实源 | 提交 |
| `test_data/` | 可复现的固定测试向量 | 提交 |
| `artifacts/` | 仅正式 bit/XSA 和必要发布校验文件 | 提交正式版；候选、失败、调试版移入本地归档 |
| `reports/` | 最终性能、实现门禁、正式串口日志和验收 Word | 提交最终证据；中间/渲染/实验结果移入本地归档 |
| `docs/` | 需求、架构、设计与实施计划 | 提交 |
| `tools/` | 协议、报告和文档生成工具 | 提交 |
| `_local/archive/` | 历史调试脚本、松散日志、失败产物、旧报告和渲染图片 | 本地保留，整体忽略 |

## 本地保留但不上传

下列内容保持原位置，避免破坏工具状态：

- `.Xil/`、`FPGA/.Xil/`
- `FPGA/FPGA.cache/`
- `FPGA/FPGA.hw/`
- `FPGA/FPGA.ip_user_files/`
- `FPGA/FPGA.runs/`
- `FPGA/FPGA.sim/`
- `FPGA/FPGA.srcs/sources_1/bd/system/{hdl,hw_handoff,ip,ipshared,sim,synth,ui}/`
- `vitis_workspace/`
- `sim/build/`

这些路径由 `.gitignore` 排除，不删除、不移动。

## 归档规则

以下零散内容移动到 `_local/archive/`，保持可找回但不上传：

- 根目录的 Vivado `.log/.jou`、备份日志和 `.Xil` 之外的临时会话文件；
- `reports/` 下的旧日期报告、Word/PDF 渲染页、中间 profiling、实验失败与调试采集；
- `artifacts/` 下的 candidate、experimental/failed、旧 debug/ILA/smartconnect/aux-reset 版本；
- 已被正式脚本取代且不再用于复现流程的临时探测、DAP 恢复和一次性 Tcl；
- 空目录、编辑器临时文件和残留 PID 文件。

移动前逐项验证目标路径在 `D:\FPGA` 内；不使用广泛递归删除。发生名称冲突时保留两份并附加原相对路径，不覆盖。

## GitHub 上传集合

GitHub 必须包含：

- 当前规范 RTL、打包 IP 源、DMA 协议、测试和软件；
- Vivado `.xpr`、Block Design、板级约束和可重建 Tcl；
- `artifacts/system_wrapper_dma_batch.bit` 与 `.xsa`；
- `reports/dma_batch/` 的正式门禁、板测和发布哈希；
- 最终验收 Word、README、架构/部署说明、设计和实施文档。

GitHub 不包含本地生成目录、Vitis workspace、候选/失败 bit、旧渲染图、调试日志、PID、缓存或 `_local/`。

## README 与复现入口

重写 README，使其反映最终 DMA 版本，至少包含：项目能力、目录结构、依赖版本、RTL 回归命令、Vivado 重建命令、Vitis 重建命令、板级烧录命令、验收结果、正式产物位置和本地生成目录说明。README 不再引用已删除或已归档的一次性脚本。

## 安全与验证

整理完成后执行：

1. `git status --ignored` 检查生成目录确实保留但被忽略；
2. 确认正式 bit/XSA、板测日志和最终 Word 的 SHA-256 未因归档改变；
3. 运行 23 个 RTL testbench 与协议生成漂移检查；
4. 运行 7 个软件布局/边界测试；
5. 运行实现报告门禁检查；
6. 检查 Git 暂存集合无 `_local/`、Vitis workspace、Vivado cache/runs 和实验失败产物；
7. 检查仓库中没有超过 GitHub 单文件限制的意外文件或凭据。

## GitHub 发布流程

在 `codex/organize-project` 分支完成整理，按明确文件范围提交；确认 `gh` 已认证后推送到 `origin`，并创建目标为 `main` 的草稿 PR。远端地址必须为 `https://github.com/fortitude24102-lang/FPGA.git`。不强推、不直接改写远端 `main`。

## 完成标准

- 本地 Vivado/Vitis 生成文件仍存在并可被原工程使用；
- 根目录只保留项目入口文件和职责明确的一级目录；
- GitHub 上传集合不含工具缓存、workspace、实验失败产物和临时日志；
- 正式交付物及证据哈希不变；
- 自动回归与门禁通过；
- 整理分支成功推送并生成草稿 PR。
