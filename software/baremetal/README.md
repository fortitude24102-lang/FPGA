# Z15 bare-metal accelerator software

This directory contains the canonical PS-side software for the Z15 molecular
accelerator. The release application uses AXI DMA simple mode, 128-bit AXI4-
Stream transfers, burst access through Zynq HP0, packet validation, mixed-task
batching, error recovery, and the 1,000-batch stress test.

The application prints through PS UART0 on MIO14/MIO15 at 115200 baud.

The TCP service adds lwIP 2.0.2 RAW API networking on PS GEM0. It uses a
static IPv4 address of `192.168.1.10/24`, listens on TCP port `5001`, supports
five simultaneous connections, queues eight complete requests, and performs
all accelerator transfers through the interrupt-driven AXI DMA path. GNN,
ADMET, and pipeline requests are accepted only after a successful reference or
network weight reload; Tanimoto remains available when weights are not ready.

## Canonical sources

- `main_dma_batch.c`: board-level acceptance and performance test.
- `main_tcp_server.c`: static-IP TCP service, connection ownership, request
  queueing, weight readiness, and accelerator dispatch.
- `mol_tcp_protocol.c/.h`: framed TCP stream parser and task-to-DMA mapping.
- `mol_dma_protocol.h`: shared wire-format constants.
- `mol_dma_queue.c/.h`: packet builder, result parser, and DMA polling driver.
- `accelerator.c/.h`: AXI-Lite control and reference weight setup.
- `platform.c/.h`: standalone platform initialization.

The earlier AXI-Lite-only `main.c` smoke test is retained only in the local
`_local/archive/` directory and is not part of the release application.

## Create or rebuild the Vitis 2019.2 application

From the Vitis XSCT console:

```tcl
source D:/FPGA/software/create_dma_vitis_app.tcl
```

The script creates `D:/FPGA/vitis_workspace`, imports the formal hardware
platform `D:/FPGA/artifacts/system_wrapper_dma_batch.xsa`, builds Debug and
Release configurations, and leaves all generated workspace files local.

If the platform and application already exist and only sources changed, run:

```tcl
source D:/FPGA/software/rebuild_dma_vitis_app.tcl
```

Program `D:/FPGA/artifacts/system_wrapper_dma_batch.bit`, download the Release
ELF, and open the serial terminal at 115200-8-N-1. The formal captured result is
in `reports/dma_batch/board-results.txt`.

## Create or rebuild the TCP service

From the Vitis 2019.2 XSCT console:

```tcl
source D:/FPGA/software/create_tcp_vitis_app.tcl
```

The script uses `D:/FPGA/artifacts/system_wrapper_tcp_service.xsa`, creates the
`z15_tcp_platform` standalone platform, enables the bundled lwIP 2.0.2 RAW API,
applies the generated-BSP-only YT8531C Clause 22 PHY patch, and builds both
Debug and Release ELFs. The XSA, bitstream, and Vitis workspace are generated
locally and ignored by Git.

After generating the matching bitstream and starting `hw_server`, program and
run the Release service with:

```tcl
source D:/FPGA/FPGA/program_tcp_service.tcl
```

The serial terminal must show `PHY address: 7`,
`TCP server: 192.168.1.10:5001`, and `weights_ready=1` before weighted requests
are sent. Connect the host Ethernet adapter to `192.168.1.x/24`; the client and
full board acceptance commands are documented in `D:/FPGA/docs/TCP服务使用说明.md`.
