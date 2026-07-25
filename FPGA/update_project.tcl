# Update the existing Vivado 2019.2 project with all completed RTL and
# SystemVerilog self-checking testbenches.
set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ".."]]
set project_file [file join $script_dir "FPGA.xpr"]

if {![file exists $project_file]} {
    error "Project not found: $project_file"
}

open_project $project_file

# Remove stale testbench references from the original partial project.
foreach stale [get_files -quiet "*tb_tanimoto.v"] {
    remove_files $stale
}
foreach stale [get_files -quiet "*tb_gnn.v"] {
    remove_files $stale
}

set rtl_sources [list \
    [file join $root_dir "rtl" "tanimoto_accelerator.v"] \
    [file join $root_dir "rtl" "gnn_message_passing.v"] \
    [file join $root_dir "rtl" "fc_network.v"] \
    [file join $root_dir "rtl" "admet_predictor.v"] \
    [file join $root_dir "rtl" "generator_accelerator_top.v"]]

set sim_sources [list \
    [file join $root_dir "sim" "tb_tanimoto.sv"] \
    [file join $root_dir "sim" "tb_gnn.sv"] \
    [file join $root_dir "sim" "tb_gnn_latency.sv"] \
    [file join $root_dir "sim" "tb_fc_network.sv"] \
    [file join $root_dir "sim" "tb_admet.sv"] \
    [file join $root_dir "sim" "tb_top.sv"]]

foreach source $rtl_sources {
    if {[llength [get_files -quiet $source]] == 0} {
        add_files -norecurse -fileset sources_1 $source
    }
}
foreach source $sim_sources {
    if {[llength [get_files -quiet $source]] == 0} {
        add_files -norecurse -fileset sim_1 $source
    }
    set_property file_type SystemVerilog [get_files $source]
}

set constraint_file [file join $root_dir "constraints" "top_timing.xdc"]
if {[llength [get_files -quiet $constraint_file]] == 0} {
    add_files -norecurse -fileset constrs_1 $constraint_file
}

set_property top generator_accelerator_top [get_filesets sources_1]
set_property top tb_top [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
save_project

puts "Project updated successfully."
puts "Synthesis top: generator_accelerator_top"
puts "Simulation top: tb_top"
