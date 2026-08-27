# 正式硬件交付物

此目录只保存已通过 Vivado 实现门禁和 Z15 实板验收的正式文件：

- `system_wrapper_dma_batch.bit`：正式可编程比特流。
- `system_wrapper_dma_batch.xsa`：Vitis 2019.2 正式硬件平台。
- `system_wrapper_tcp_service.bit`：带千兆网服务和 800×480 LCD 面板的演示比特流。
- `system_wrapper_tcp_service.xsa`：TCP/LCD 演示版硬件平台。
- `accelerator_tcp_server.elf`：Cortex-A9 Release 版 TCP 加速服务。

SHA-256 以 `reports/dma_batch/release-hashes.sha256` 为准。当前值：

```text
81EF25EEAA2ADB1783A28EAADCF305367E00756319CCEB973B5AD308FF9ABC3E  artifacts/system_wrapper_dma_batch.bit
736397FA243D1A30CBDAD151C1C3CFA19A0B0D1168BA68FE027A55ABFDEB6A61  artifacts/system_wrapper_dma_batch.xsa
0C3295594B829BA4A27F64B2018CCB0AF7B0AC0DC4302D196FBA6BDE93403B16  artifacts/system_wrapper_tcp_service.bit
216CF05CBCC1D559DCCDD8B143B469442517B27C7952605EC85975C4E211FB0D  artifacts/system_wrapper_tcp_service.xsa
9DA0B265DDF6D8A2B0BB18A50F9C6F255D2CD908CBF36CB7D720CCB7E878F5F4  artifacts/accelerator_tcp_server.elf
```

DMA 性能基线通过正式时序门禁。TCP/LCD 演示版通过实板功能验收，但最新实现
报告仍记录负 WNS；两者的验收口径不得混用。

`FPGA/rebuild_dma_batch.tcl` 的新输出进入被忽略的
`artifacts/candidate_dma_batch/`，对应报告进入
`reports/candidate_dma_batch/`。候选文件不得自动覆盖本目录的正式文件；
必须先通过报告门禁、软件构建和完整实板回归，再显式晋升。
