# Z15 分子计算 FPGA 加速器

本仓库实现 MolRecommender 项目的 Zynq-7015 硬件加速核心，覆盖
Tanimoto 分子指纹相似度、GNN 消息传递、四路 ADMET 全连接网络以及
Tanimoto → GNN → ADMET 流水线。最终版本在原 AXI4-Lite 控制面之外加入
AXI DMA、128-bit AXI4-Stream、HP0 突发传输和混合任务批处理，并完成
RTL、软件、实现报告及 Z15 实板闭环验证。

## 最终验收结果

硬件平台：ALINX Z15，`XC7Z015CLG485-2`

工具版本：Vivado/Vitis 2019.2

串口：PS UART0，MIO14/MIO15，115200-8-N-1

| 项目 | 实测结果 | 目标 | 状态 |
|---|---:|---:|:---:|
| Tanimoto，共享查询 N=64 | 32 μs，20.62× | ≥20× | PASS |
| Tanimoto 纯计算核心 | 5 cycles，120.00× | ≥50× | PASS |
| GNN summary/full | 796 μs，33.84× | ≥10× | PASS |
| ADMET N=64 | 97 μs，21.11× | ≥20× | PASS |
| Pipeline 三种输出模式 | 1087 μs，37.28× | ≥30× | PASS |
| MM2S，2 MiB | 1198.37 MB/s | ≥500 MB/s | PASS |
| S2MM，2 MiB | 1199.74 MB/s | ≥500 MB/s | PASS |

实板同时通过三组 Tanimoto 参考向量、GNN summary/full、ADMET N=64、
Pipeline default/intermediate/full、0/1/2/3 混合批次、continue/stop-on-error、
任务超时、DMA reset recovery 和 1,000 批压力测试。完整串口证据见
[`reports/dma_batch/board-results.txt`](reports/dma_batch/board-results.txt)。

实现结果满足正时与资源门禁：100 MHz WNS/WHS 为 `+0.012/+0.010 ns`，
150 MHz WNS/WHS 为 `+0.460/+0.060 ns`，无未布线网络、DRC Error 或
Methodology Error；使用 31,133 LUT、16,707 FF、21 BRAM、78 DSP48。

## 验证覆盖

- 23 个自检式 RTL testbench 全部通过。
- DMA 协议代码生成一致性检查通过。
- 7 个 PS 端数据布局与边界条件软件测试通过。
- Vivado 实现报告自动门禁通过。
- AXI4-Lite 兼容性回归保持 `ALL COMPREHENSIVE SELF-TESTS PASSED`。

在仓库根目录运行完整 RTL 与协议回归：

```powershell
python sim/run_tests.py --test all
```

运行软件布局测试与实现报告门禁：

```powershell
wsl.exe bash -lc "cd /mnt/d/FPGA && python3 -m unittest software/tests/test_mol_dma_layout.py"
python FPGA/check_dma_reports.py reports/dma_batch/impl
```

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/` | 可综合计算核心、DMA 前后端、批处理后端和 AXI4-Lite 顶层 |
| `protocol/` | DMA 请求/响应协议唯一事实源及生成结果 |
| `sim/` | 23 个 SystemVerilog testbench、一键回归和协议检查 |
| `software/` | Vitis/Standalone 驱动、包构造器、结果解析器和实板测试 |
| `FPGA/` | Vivado 2019.2 工程、BD、XCI 与可复现 Tcl |
| `ip_repo/` | 自定义加速器 IP 打包源 |
| `constraints/` | 顶层时序约束；板级约束随 IP 源保存 |
| `artifacts/` | 正式 bit/XSA 交付物 |
| `reports/dma_batch/` | 正式板测、实现、性能、构建与发布哈希证据 |
| `docs/` | 项目需求、报告模板、设计说明和实施记录 |
| `asm/`、`test_data/` | Python 参考基准与固定点测试数据 |
| `tools/` | 协议生成、文档处理和本地工作区整理工具 |

完整分类规则见 [`docs/PROJECT_STRUCTURE.md`](docs/PROJECT_STRUCTURE.md)。

## Vivado 2019.2

现有工程入口为 [`FPGA/FPGA.xpr`](FPGA/FPGA.xpr)。更新源文件集时，在
Vivado Tcl Console 执行：

```tcl
source D:/FPGA/FPGA/update_project.tcl
```

重新生成 DMA/突发/批处理候选实现：

```powershell
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch `
  -source 'D:\FPGA\FPGA\rebuild_dma_batch.tcl'
python D:\FPGA\FPGA\check_dma_reports.py D:\FPGA\reports\dma_batch\impl
```

该脚本把候选 bit/XSA 写入本地忽略的 `artifacts/candidate_dma_batch/`，
避免自动覆盖正式交付物。候选通过报告门禁和实板回归后，再显式晋升为
正式版本。

## Vitis 2019.2 与上板

在 XSCT 中创建平台和 Debug/Release 应用：

```tcl
source D:/FPGA/software/create_dma_vitis_app.tcl
```

脚本默认使用正式硬件平台
[`artifacts/system_wrapper_dma_batch.xsa`](artifacts/system_wrapper_dma_batch.xsa)，
生成内容保留在本地 `vitis_workspace/`，不会提交到 GitHub。仅更新软件源时可
执行 `source D:/FPGA/software/rebuild_dma_vitis_app.tcl`。

板卡上电并连接 JTAG 与 UART 后运行：

```powershell
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' `
  'D:\FPGA\FPGA\program_dma_batch.tcl'
```

## 正式交付物

- [`artifacts/system_wrapper_dma_batch.bit`](artifacts/system_wrapper_dma_batch.bit)

  SHA-256: `81EF25EEAA2ADB1783A28EAADCF305367E00756319CCEB973B5AD308FF9ABC3E`
- [`artifacts/system_wrapper_dma_batch.xsa`](artifacts/system_wrapper_dma_batch.xsa)

  SHA-256: `736397FA243D1A30CBDAD151C1C3CFA19A0B0D1168BA68FE027A55ABFDEB6A61`
- [`reports/Z15_FPGA项目验收与测试报告_20260811_DMA最终版.docx`](reports/Z15_FPGA项目验收与测试报告_20260811_DMA最终版.docx)

发布哈希清单见
[`reports/dma_batch/release-hashes.sha256`](reports/dma_batch/release-hashes.sha256)。

## 本地生成目录

`.Xil/`、`FPGA/FPGA.cache/`、`FPGA/FPGA.hw/`、`FPGA/FPGA.runs/`、
`FPGA/FPGA.sim/`、生成的 BD 子目录和 `vitis_workspace/` 均保留在本机，
但由 `.gitignore` 排除。整理前的历史调试文件位于本机
`_local/archive/<原相对路径>/`；该目录同样不会上传。
