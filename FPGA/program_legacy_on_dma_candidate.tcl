# Run the preserved legacy comprehensive AXI-Lite self-test on the final
# DMA-capable candidate to prove backward compatibility.

set bit_file D:/FPGA/artifacts/system_wrapper_dma_batch.bit
set elf_file D:/FPGA/vitis_workspace/accelerator_selftest/Debug/accelerator_selftest.elf
set ps7_init_file D:/FPGA/vitis_workspace/z15_dma_platform/hw/ps7_init.tcl

foreach required_file [list $bit_file $elf_file $ps7_init_file] {
    if {![file exists $required_file]} {
        error "Required board file does not exist: $required_file"
    }
}

connect -url tcp:127.0.0.1:3121
targets -set -filter {name =~ "APU"}
catch {stop}
rst -system
after 1000
targets -set -filter {name =~ "xc7z015"}
fpga -file $bit_file
after 1000
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
source $ps7_init_file
ps7_init
ps7_post_config
catch {stop}
rst -processor
after 200
dow $elf_file
con
puts "LEGACY_SELFTEST_RUNNING=$elf_file"
disconnect
exit
