# Z15 分子加速器 TCP 服务使用说明

## 1. 硬件连接

需要同时连接三条通道：

1. JTAG：用于下载 bitstream 和 ELF。
2. USB-UART：连接 PS UART0（MIO14/MIO15），电平为 3.3 V，串口参数为 115200-8-N-1。
3. 以太网：开发板网口连接电脑的有线网卡或 USB 转网口。

将电脑有线网卡设置为静态地址 `192.168.1.2`、掩码 `255.255.255.0`，直连时不填写网关。开发板固定地址为 `192.168.1.10/24`，TCP 端口为 `5001`。

## 2. 从干净检出构建

Vivado 2019.2 与 Vitis 2019.2 安装在 `D:\visit` 时，在 PowerShell 中依次执行：

```powershell
cd D:\FPGA

& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source 'D:\FPGA\FPGA\package_dma_accelerator_ip.tcl'
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source 'D:\FPGA\FPGA\add_dma_batch_system.tcl'
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source 'D:\FPGA\FPGA\check_dma_batch_bd.tcl'
& 'D:\visit\Vivado\2019.2\bin\vivado.bat' -mode batch -source 'D:\FPGA\FPGA\rebuild_dma_batch.tcl'

py -3 FPGA/check_dma_reports.py reports/candidate_dma_batch/impl

Copy-Item -Force 'D:\FPGA\artifacts\candidate_dma_batch\system_wrapper_dma_batch.bit' `
  'D:\FPGA\artifacts\system_wrapper_tcp_service.bit'
Copy-Item -Force 'D:\FPGA\artifacts\candidate_dma_batch\system_wrapper_dma_batch.xsa' `
  'D:\FPGA\artifacts\system_wrapper_tcp_service.xsa'

$env:MOL_TCP_XSA='D:\FPGA\artifacts\system_wrapper_tcp_service.xsa'
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' 'D:\FPGA\software\create_tcp_vitis_app.tcl'
Copy-Item -Force 'D:\FPGA\vitis_workspace\accelerator_tcp_server\Release\accelerator_tcp_server.elf' `
  'D:\FPGA\artifacts\accelerator_tcp_server.elf'
```

构建采用 100 MHz 加速器控制/计算时钟与 125 MHz HP0/DMA/AXIS 时钟。启用 PS GEM0 后共享 IO PLL 固定为 1000 MHz，无法精确产生原计划的 150 MHz，因此按照设计允许的回退方案明确使用 125 MHz。正式门禁要求实现报告中同时存在精确的 `10.000 ns` 和 `8.000 ns` 时钟，并要求两者 setup/hold slack 均为正；不接受隐式的 142.857 MHz。

## 3. 烧录

构建完成后执行：

```powershell
cd D:\FPGA
$env:MOL_TCP_BIT='D:\FPGA\artifacts\system_wrapper_tcp_service.bit'
$env:MOL_TCP_ELF='D:\FPGA\artifacts\accelerator_tcp_server.elf'
& 'D:\visit\Vitis\2019.2\bin\xsct.bat' 'D:\FPGA\FPGA\program_tcp_service.tcl'
```

烧录脚本依次下载 `artifacts/system_wrapper_tcp_service.bit` 和 Release ELF，然后启动 Cortex-A9 #0。每次开发板断电后都必须重新烧录。

## 4. 启动检查

烧录前打开串口终端。正常启动至少出现：

```text
Z15 molecular accelerator TCP service
PHY address: 7
TCP server: 192.168.1.10:5001
DMA mode: interrupt
weights_ready=1 epoch=1
```

若电脑无法连接 `192.168.1.10`，先确认 Windows 中确实出现了有线网卡，并检查该网卡是否为 `192.168.1.2/24`。若路由走向 Wi-Fi 网关，则有线网卡尚未正确连接或配置。

## 5. 完整验收

在 `D:\FPGA` 运行：

```powershell
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 queue-test
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 reload test_data/selftest_weights.bin
py -3 software/host/mol_tcp_client.py --host 192.168.1.10 selftest
```

验收判据：

- 两次 `selftest` 均通过 Tanimoto、GNN、ADMET 和 Pipeline。
- `queue-test` 验证 5 个并发连接、8 项全局 FIFO 顺序，以及队列满时的 busy 响应。
- `reload` 返回成功，权重 epoch 增加；热重载后第二次 `selftest` 仍全部通过。
- UART 在 DMA 传输后输出 `DMA_IRQ_COUNTS mm2s=... s2mm=... polling=0`，计数持续增加。
- 客户端退出后再次运行命令可以重新连接，证明断开/重连正常。
- 服务器会回收约 30 秒没有组成完整帧的连接，避免 5 个残缺帧永久占满连接槽。
- 畸形帧会关闭当前连接，但不会影响后续客户端重新连接和正常请求。

`selftest_weights.bin` 与服务启动时的确定性稀疏权重完全一致，用于验证“重载后固定输出不变”。`reference_weights.bin` 是合成数据集的完整模型权重，加载后 GNN、ADMET 和 Pipeline 输出按模型变化，不能再用固定输出的 `selftest` 判定。

## 6. 本地生成物

以下文件用于烧录，但被 `.gitignore` 排除，不提交 GitHub：

- `artifacts/system_wrapper_tcp_service.bit`
- `artifacts/system_wrapper_tcp_service.xsa`
- `artifacts/accelerator_tcp_server.elf`
- `vitis_workspace/`

这些文件会保留在本机，便于下一次直接烧录，但按项目策略不提交到 GitHub。Vivado 工程生成的 `.xpr`、`.bd`、IP 打包输出与 runs/cache 同样只保留在本地。

正式构建证据位于 `reports/tcp_service/build-results.txt`，上板证据位于 `reports/tcp_service/board-results.txt`。
