# Vivado 与开发板部署步骤

## 1. 打开工程

使用 Vivado 2019.2 打开：

```text
D:\FPGA\FPGA\FPGA.xpr
```

器件应为：

```text
xc7z015clg485-2
```

如果文件列表没有刷新，在 Tcl Console 运行：

```tcl
source D:/FPGA/FPGA/update_project.tcl
```

## 2. Vivado 仿真

在 Simulation Sources 中依次选择需要的 Top：

```text
tb_tanimoto
tb_gnn
tb_gnn_latency
tb_fc_network
tb_admet
tb_top
```

执行 Behavioral Simulation，运行到 `$finish`。日志必须出现对应的
`ALL ... TESTS PASSED`。

## 3. 综合与实现

将 Design Sources 的 Top 设置为：

```text
generator_accelerator_top
```

确认 `constraints/top_timing.xdc` 已启用。旧工程结果只包含原始
Tanimoto/Divider IP，因此必须先 Reset Runs，再重新执行：

1. Run Synthesis；
2. Open Synthesized Design；
3. 查看 Utilization、Timing Summary 和 RAM/DSP 推断；
4. Run Implementation；
5. 确认 WNS >= 0、TNS = 0；
6. Generate Bitstream。

需要保存的报告：

```tcl
report_utilization -file D:/FPGA/reports/utilization.rpt
report_timing_summary -file D:/FPGA/reports/timing_summary.rpt
report_drc -file D:/FPGA/reports/drc.rpt
```

如果 RAM 没有推断成 Block RAM，应先检查综合日志中的 RAM inference
信息，再考虑调整 RAM 模板；不要直接把资源指标写成“已通过”。

## 4. 权重和数据

当前 `test_data/` 是确定性合成数据，只用于验证接口和固定点计算。正式演示
前必须替换成训练完成并量化为 Q8.8 的权重。

真实 SMILES 数据可通过：

```powershell
python D:\FPGA\asm\generate_test_data.py `
  --smiles-file D:\FPGA\smiles.txt
```

生成。该模式需要 RDKit。

## 5. 上板检查

1. 下载 bitstream；
2. 写入 Tanimoto 两组指纹并启动 task 0；
3. 读取状态和 Q16.16 结果，与 Python/RDKit 对比；
4. 写入 GNN 权重、邻接矩阵和特征，启动 task 1；
5. 写入四组 ADMET 权重和 descriptors，启动 task 2；
6. 启动 task 3，确认三个阶段按顺序完成；
7. 记录纯计算时间和包含 AXI/TCP 传输的端到端时间；
8. 将实测时间保存到 `fpga_timings.json`，运行性能脚本。

## 6. 后端联调约定

后端和 FPGA 端至少要统一：

- 所有多字数据的低地址对应低有效位；
- Q8.8 和 Q16.16 的有符号性、字节序和饱和规则；
- 邻接位编号为 `destination*MAX_NODES + source`；
- GNN 权重地址为 `feature*HIDDEN_DIM + hidden`；
- 超时、错误状态和 FPGA 断开后的 Python 降级行为。
