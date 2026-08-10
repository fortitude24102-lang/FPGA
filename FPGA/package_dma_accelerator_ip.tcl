set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $root_dir rtl]
set core_dir [file join $root_dir ip_repo generator_accelerator_1_0]
set src_dir [file join $core_dir src]
set component [file join $core_dir component.xml]

set rtl_files {
    admet_predictor.v
    fc_network.v
    gnn_message_passing.v
    tanimoto_accelerator.v
    tanimoto_stream_batch.v
    dma_task_queue_frontend.v
    dma_task_queue.v
    dma_result_formatter.v
    dma_accelerator_backend.v
    generator_accelerator_top.v
    mol_dma_protocol.vh
}

set missing {}
foreach name $rtl_files {
    if {![file exists [file join $rtl_dir $name]]} {
        lappend missing [file join $rtl_dir $name]
    }
}
foreach required [list $component [file join $core_dir xgui \
                                  generator_accelerator_top_v1_0.tcl]] {
    if {![file exists $required]} { lappend missing $required }
}
if {[llength $missing] != 0} {
    foreach name $missing { puts "PREFLIGHT_MISSING: $name" }
    error "DMA accelerator packaging preflight failed"
}

file mkdir $src_dir
foreach name $rtl_files {
    file copy -force [file join $rtl_dir $name] [file join $src_dir $name]
}

create_project -in_memory -part xc7z015clg485-2
set project_sources {}
foreach name $rtl_files {
    if {[file extension $name] ne ".vh"} {
        lappend project_sources [file join $src_dir $name]
    }
}
add_files -norecurse $project_sources
set_property include_dirs $src_dir [current_fileset]
set_property top generator_accelerator_top [current_fileset]
update_compile_order -fileset sources_1

set core [ipx::open_core $component]
ipx::merge_project_changes ports $core

foreach group_name {xilinx_anylanguagesynthesis \
                    xilinx_anylanguagebehavioralsimulation} {
    set group [ipx::get_file_groups -quiet $group_name -of_objects $core]
    if {[llength $group] != 1} {
        error "Required IP file group not found: $group_name"
    }
    foreach name $rtl_files {
        set relative [file join src $name]
        set existing [ipx::get_files -quiet $relative -of_objects $group]
        if {[llength $existing] == 0} {
            set item [ipx::add_file $relative $group]
            if {[file extension $name] eq ".vh"} {
                set_property type verilogSource $item
                set_property is_include true $item
            } else {
                set_property type verilogSource $item
            }
        }
    }
}

proc ensure_axis_interface {core name mode prefix} {
    set bus [ipx::get_bus_interfaces -quiet $name -of_objects $core]
    if {[llength $bus] == 0} {
        set bus [ipx::add_bus_interface $name $core]
    }
    set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 $bus
    set_property bus_type_vlnv xilinx.com:interface:axis:1.0 $bus
    set_property interface_mode $mode $bus

    foreach logical {TDATA TKEEP TLAST TVALID TREADY} {
        set map [ipx::get_port_maps -quiet $logical -of_objects $bus]
        if {[llength $map] == 0} {
            set map [ipx::add_port_map $logical $bus]
        }
        set suffix [string tolower $logical]
        set_property physical_name ${prefix}_${suffix} $map
    }

    foreach {parameter value} {
        TDATA_NUM_BYTES 16
        HAS_TKEEP 1
        HAS_TLAST 1
    } {
        set item [ipx::get_bus_parameters -quiet $parameter -of_objects $bus]
        if {[llength $item] == 0} {
            set item [ipx::add_bus_parameter $parameter $bus]
        }
        set_property value $value $item
    }
}

ensure_axis_interface $core s_axis_job slave s_axis_job
ensure_axis_interface $core m_axis_result master m_axis_result

set clk [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
set associated [ipx::get_bus_parameters -quiet ASSOCIATED_BUSIF \
                -of_objects $clk]
if {[llength $associated] == 0} {
    set associated [ipx::add_bus_parameter ASSOCIATED_BUSIF $clk]
}
set_property value s_axi:s_axis_job:m_axis_result $associated

set reset [ipx::get_bus_interfaces s_axi_aresetn -of_objects $core]
set reset_polarity [ipx::get_bus_parameters -quiet POLARITY \
                    -of_objects $reset]
if {[llength $reset_polarity] != 0} {
    set_property value ACTIVE_LOW $reset_polarity
}

set_property core_revision 7 $core
set_property display_name {Z15 Molecular Accelerator with DMA Batch Streams} $core
set_property description \
    {Tanimoto, GNN, ADMET and pipeline accelerator with AXI-Lite legacy control and 128-bit AXIS DMA batches} $core

ipx::update_checksums $core
ipx::save_core $core
ipx::check_integrity -quiet $core
puts "DMA_ACCELERATOR_IP_PACKAGED=[get_property VLNV $core]"
ipx::unload_core $core

# Vivado rewrites this informational timestamp on every save.  Normalize it
# so two packaging passes produce byte-identical metadata.
set handle [open $component r]
set xml [read $handle]
close $handle
regsub {<xilinx:coreCreationDateTime>[^<]*</xilinx:coreCreationDateTime>} \
       $xml \
       {<xilinx:coreCreationDateTime>2000-01-01T00:00:00Z</xilinx:coreCreationDateTime>} \
       xml
set handle [open $component w]
puts -nonewline $handle $xml
close $handle

close_project
exit
