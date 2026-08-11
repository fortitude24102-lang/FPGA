# Program and run the production DMA/burst/batch candidate on Z15.
# Usage:
#   xsct.bat D:/FPGA/FPGA/program_dma_batch.tcl

set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set bit_file [file join $root_dir artifacts system_wrapper_dma_batch.bit]
set elf_file [file join $root_dir vitis_workspace accelerator_dma_batch \
              Release accelerator_dma_batch.elf]
set ps7_init_file [file join $root_dir vitis_workspace z15_dma_platform \
                   hw ps7_init.tcl]
if {[info exists ::env(MOL_DMA_BIT)] && $::env(MOL_DMA_BIT) ne ""} {
    set bit_file [file normalize $::env(MOL_DMA_BIT)]
}
if {[info exists ::env(MOL_DMA_ELF)] && $::env(MOL_DMA_ELF) ne ""} {
    set elf_file [file normalize $::env(MOL_DMA_ELF)]
}

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

puts "DMA_BATCH_PROGRAMMED_BIT=$bit_file"
puts "DMA_BATCH_RUNNING_ELF=$elf_file"
disconnect
exit
