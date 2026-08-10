set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project_file [file join $script_dir FPGA.xpr]
set output_dir [file join $root_dir artifacts candidate_dma_batch]
set output_xsa [file join $output_dir system_wrapper_dma_batch_nobit.xsa]

file mkdir $output_dir
open_project $project_file
write_hw_platform -fixed -force -file $output_xsa
puts "DMA_BATCH_NOBIT_XSA=$output_xsa"
close_project
exit
