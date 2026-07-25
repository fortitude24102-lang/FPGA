# FPGA 分子计算加速项目

本项目实现任务文档要求的三个计算模块、AXI4-Lite 顶层、SystemVerilog
自检式 Testbench、测试数据生成脚本和 Python 性能基准脚本。

## 当前完成状态

- `tanimoto_accelerator.v`：1024 位指纹、平衡 popcount、Q16.16
  恢复式除法，包含除零处理。
- `gnn_message_passing.v`：50×64×128 参数化消息传递，Q8.8、邻居求和、
  线性变换和 ReLU；生产模式使用 32 位 BRAM 读写端口。
- `fc_network.v`：参数化 `INPUT -> HIDDEN -> OUTPUT`，ReLU 和分段线性
  Sigmoid。
- `admet_predictor.v`：四个 `20 -> 10 -> 1` 网络并行计算。
- `generator_accelerator_top.v`：AXI4-Lite、任务调度和
  `IDLE -> LOAD -> EXECUTE -> OUTPUT -> DONE` 状态机。
- 6 个 SystemVerilog Testbench 已用 Icarus Verilog 12.0 全部通过。
- 默认 GNN 实测 RTL 延迟为 582,550 个周期，即 100 MHz 下 5.8255 ms。
- 已生成四组无第三方依赖的合成测试数据。

尚未在本机确认的项目是 Vivado 仿真、综合、实现、时序、最终资源占用和
开发板实测加速比。这些结果必须由 Vivado/真实硬件产生，不能用
Icarus 结果代替。

## 目录

```text
rtl/          可综合 RTL
sim/          SystemVerilog Testbench 和一键回归脚本
asm/          测试数据与性能基准 Python 脚本
test_data/    已生成的 Q8.8/Q16.16 测试向量
constraints/  100 MHz 时钟约束
FPGA/         Vivado 2019.2 工程与更新脚本
reports/      架构、验证、部署和性能报告
```

原始文件已经保存在 `backup_before_codex_20260723_112014/`。

## 快速回归

在 PowerShell 中运行：

```powershell
python D:\FPGA\sim\run_tests.py
```

运行单个测试：

```powershell
python D:\FPGA\sim\run_tests.py --test tanimoto
python D:\FPGA\sim\run_tests.py --test gnn
python D:\FPGA\sim\run_tests.py --test gnn_latency
python D:\FPGA\sim\run_tests.py --test fc_network
python D:\FPGA\sim\run_tests.py --test admet
python D:\FPGA\sim\run_tests.py --test top
```

## 测试数据

不安装第三方包也能生成合成向量：

```powershell
python D:\FPGA\asm\generate_test_data.py --synthetic
```

使用真实 SMILES 时需安装 RDKit，并准备一行一个 SMILES 的文本文件：

```powershell
python D:\FPGA\asm\generate_test_data.py `
  --smiles-file D:\FPGA\smiles.txt
```

生成器会输出指纹、图特征、邻接矩阵、GNN 权重、四个 ADMET 网络权重及
固定点参考结果。`manifest.json` 记录维度、随机种子和所有参考值。

## Python 基准

```powershell
python D:\FPGA\asm\benchmark_python.py
```

有开发板实测时间后，创建如下 JSON：

```json
{
  "tanimoto_ms": 0.001,
  "gnn_ms": 1.0,
  "admet_ms": 0.01,
  "end_to_end_ms": 1.1
}
```

然后运行：

```powershell
python D:\FPGA\asm\benchmark_python.py `
  --fpga-results D:\FPGA\fpga_timings.json
```

脚本会计算 50×、10×、20×和 30×四项加速目标是否达标。

## Vivado 2019.2

工程器件为 `xc7z015clg485-2`。`FPGA.xpr` 已加入全部 RTL、`.sv`
Testbench 和 100 MHz 约束。若 Vivado 没有刷新文件集，在 Tcl Console
运行：

```tcl
source D:/FPGA/FPGA/update_project.tcl
```

仿真时将 `sim_1` 的 Top 切换到需要的 Testbench。建议至少运行：

```text
tb_tanimoto
tb_gnn
tb_fc_network
tb_admet
tb_top
tb_gnn_latency
```

综合前将设计 Top 设为 `generator_accelerator_top`，重置旧的
`synth_1/impl_1` 结果后重新运行。原工程中的 `div_gen_0` 已不再被 RTL
引用，可以保留，也可以在确认新工程通过后移除。

详细接口和地址定义见 `reports/architecture.md`；Vivado/上板步骤见
`reports/deployment.md`。
