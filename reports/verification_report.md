# RTL 验证报告

## 环境

- 日期：2026-07-23
- 仿真器：Icarus Verilog 12.0 (devel)
- 编译参数：`-g2012 -Wall`
- 时钟：10 ns，即 100 MHz
- 回归命令：`python D:\FPGA\sim\run_tests.py`

## 结果

| Testbench | 覆盖内容 | 结果 |
|---|---|---|
| `tb_tanimoto.sv` | 相同、互斥、空指纹、随机输入、忙时 start | PASS，7/7 |
| `tb_gnn.sv` | 邻居聚合、signed Q8.8、矩阵乘法、ReLU | PASS，6/6 |
| `tb_gnn_latency.sv` | 默认 50×64×128 周期数 | PASS，582,550 周期 |
| `tb_fc_network.sv` | 矩阵乘法、ReLU、Sigmoid、偏置缩放 | PASS，3/3 |
| `tb_admet.sv` | 四个 FC 网络同时完成并输出 | PASS，4/4 |
| `tb_top.sv` | AXI 写读、Tanimoto 调度、GNN BRAM 读回 | PASS |

默认参数的 `generator_accelerator_top` 也使用 Icarus 独立编译通过。

## 已修复的原项目问题

- 五个任务文件原来为空；
- Tanimoto 依赖 Xilinx `div_gen_0`，无法做跨工具仿真；
- 除零状态不产生 `valid`，旧 Testbench 会永久等待；
- 旧 Testbench 在忙时发送第二个 start，却错误地等待两个输出；
- GNN 的 `node_idx` 被多个 always 块驱动；
- GNN 聚合状态机无法正常结束；
- GNN MAC 漏掉最后一项乘积；
- signed Q8.8 乘法未进行小数位恢复；
- 大规模 packed 输入/输出会产生不可接受的触发器数量；
- 原 AXI 数据范围不足以容纳两个 1024 位指纹。

## 尚未完成的验证

以下项目必须由用户在 Vivado/开发板上执行：

- Vivado XSim 回归；
- 综合、布局布线和 100 MHz 时序收敛；
- LUT、FF、BRAM 和 DSP 资源报告；
- 使用训练后真实权重与 RDKit/PyTorch 数据集做误差统计；
- TCP/后端联调、断线降级和 10 万/100 万分子压力测试；
- FPGA 实测时间和最终加速比。
