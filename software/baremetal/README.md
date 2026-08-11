# Z15 bare-metal DMA batch test

This directory contains the canonical PS-side software for the Z15 molecular
accelerator. The release application uses AXI DMA simple mode, 128-bit AXI4-
Stream transfers, burst access through Zynq HP0, packet validation, mixed-task
batching, error recovery, and the 1,000-batch stress test.

The application prints through PS UART0 on MIO14/MIO15 at 115200 baud.

## Canonical sources

- `main_dma_batch.c`: board-level acceptance and performance test.
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
