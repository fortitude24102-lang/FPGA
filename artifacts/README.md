# 正式硬件交付物

此目录只保存已通过 Vivado 实现门禁和 Z15 实板验收的正式文件：

- `system_wrapper_dma_batch.bit`：正式可编程比特流。
- `system_wrapper_dma_batch.xsa`：Vitis 2019.2 正式硬件平台。

SHA-256 以 `reports/dma_batch/release-hashes.sha256` 为准。当前值：

```text
81EF25EEAA2ADB1783A28EAADCF305367E00756319CCEB973B5AD308FF9ABC3E  artifacts/system_wrapper_dma_batch.bit
736397FA243D1A30CBDAD151C1C3CFA19A0B0D1168BA68FE027A55ABFDEB6A61  artifacts/system_wrapper_dma_batch.xsa
```

`FPGA/rebuild_dma_batch.tcl` 的新输出进入被忽略的
`artifacts/candidate_dma_batch/`，对应报告进入
`reports/candidate_dma_batch/`。候选文件不得自动覆盖本目录的正式文件；
必须先通过报告门禁、软件构建和完整实板回归，再显式晋升。
