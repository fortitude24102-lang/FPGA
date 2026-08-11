set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set workspace [file join $root_dir vitis_workspace]
set source_dir [file join $script_dir baremetal src]
set app_name accelerator_dma_batch

setws $workspace
foreach source_file {
    accelerator.c accelerator.h
    mol_dma_protocol.h mol_dma_queue.c mol_dma_queue.h
    platform.c platform.h main_dma_batch.c
} {
    importsources -name $app_name -path [file join $source_dir $source_file]
}
app config -name $app_name build-config Debug
app build -name $app_name
app config -name $app_name build-config Release
app build -name $app_name
puts "DMA_APP_REBUILD_COMPLETE"
exit
