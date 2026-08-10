set script_dir [file dirname [file normalize [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set core_dir [file join $root_dir ip_repo generator_accelerator_1_0]
set component [file join $core_dir component.xml]

if {![file exists $component]} {
    error "Packaged IP component not found: $component"
}

set core [ipx::open_core $component]
set failures {}

foreach {bus_name mode} {s_axis_job slave m_axis_result master} {
    set bus [ipx::get_bus_interfaces -quiet $bus_name -of_objects $core]
    if {[llength $bus] != 1} {
        lappend failures "missing bus interface $bus_name"
        continue
    }
    if {[get_property INTERFACE_MODE $bus] ne $mode} {
        lappend failures "$bus_name mode is not $mode"
    }
    foreach logical {TDATA TKEEP TLAST TVALID TREADY} {
        set maps [ipx::get_port_maps -quiet $logical -of_objects $bus]
        if {[llength $maps] != 1} {
            lappend failures "$bus_name missing $logical port map"
        }
    }
}

foreach {port_name expected_width} {
    s_axis_job_tdata 128 s_axis_job_tkeep 16 s_axis_job_tvalid 1
    s_axis_job_tready 1 s_axis_job_tlast 1
    m_axis_result_tdata 128 m_axis_result_tkeep 16 m_axis_result_tvalid 1
    m_axis_result_tready 1 m_axis_result_tlast 1
} {
    set port [ipx::get_ports -quiet $port_name -of_objects $core]
    if {[llength $port] != 1} {
        lappend failures "missing model port $port_name"
        continue
    }
    set left [get_property SIZE_LEFT $port]
    set right [get_property SIZE_RIGHT $port]
    set width 1
    if {$left ne "" && $right ne ""} {
        set width [expr {abs($left-$right)+1}]
    }
    if {$width != $expected_width} {
        lappend failures "$port_name width $width, expected $expected_width"
    }
}

set synth_group [ipx::get_file_groups -quiet \
    xilinx_anylanguagesynthesis -of_objects $core]
set packaged_files {}
foreach item [ipx::get_files -quiet -of_objects $synth_group] {
    lappend packaged_files [get_property NAME $item]
}
foreach required {
    src/mol_dma_protocol.vh
    src/dma_task_queue_frontend.v
    src/dma_task_queue.v
    src/dma_result_formatter.v
    src/dma_accelerator_backend.v
    src/generator_accelerator_top.v
} {
    if {[lsearch -exact $packaged_files $required] < 0} {
        lappend failures "synthesis fileset missing $required"
    }
}

set clk [ipx::get_bus_interfaces -quiet s_axi_aclk -of_objects $core]
if {[llength $clk] == 1} {
    set assoc [get_property VALUE [ipx::get_bus_parameters -quiet \
        ASSOCIATED_BUSIF -of_objects $clk]]
    foreach name {s_axi s_axis_job m_axis_result} {
        if {[lsearch -exact [split $assoc :] $name] < 0} {
            lappend failures "clock ASSOCIATED_BUSIF missing $name"
        }
    }
} else {
    lappend failures "missing s_axi_aclk clock interface"
}

if {[llength $failures] != 0} {
    foreach failure $failures { puts "CHECK_FAIL: $failure" }
    ipx::unload_core $core
    error "Packaged DMA accelerator check failed with [llength $failures] issue(s)"
}

ipx::check_integrity -quiet $core
puts "PACKAGED_DMA_IP_CHECK_PASSED"
ipx::unload_core $core
exit
