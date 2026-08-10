set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir FPGA.xpr]
set bd_file [file join $script_dir FPGA.srcs sources_1 bd system system.bd]

if {[current_project -quiet] eq ""} {
    open_project $project_file
}
if {[current_bd_design -quiet] eq ""} {
    open_bd_design $bd_file
}

set failures {}

proc check_cell {name} {
    if {[llength [get_bd_cells -quiet $name]] != 1} {
        lappend ::failures "missing cell $name"
        return 0
    }
    return 1
}

proc check_intf_link {first second} {
    set first_pin [get_bd_intf_pins -quiet $first]
    set second_pin [get_bd_intf_pins -quiet $second]
    if {[llength $first_pin] != 1 || [llength $second_pin] != 1} {
        lappend ::failures "missing interface pin for $first <-> $second"
        return
    }
    set first_nets [get_bd_intf_nets -quiet -of_objects $first_pin]
    set second_nets [get_bd_intf_nets -quiet -of_objects $second_pin]
    if {[llength $first_nets] != 1 || $first_nets ne $second_nets} {
        lappend ::failures "interface not connected: $first <-> $second"
    }
}

proc check_pin_net {pin_name expected_source} {
    set pin [get_bd_pins -quiet $pin_name]
    set source [get_bd_pins -quiet $expected_source]
    if {[llength $pin] != 1 || [llength $source] != 1} {
        lappend ::failures "missing clock/reset pin $pin_name or $expected_source"
        return
    }
    set pin_net [get_bd_nets -quiet -of_objects $pin]
    set source_net [get_bd_nets -quiet -of_objects $source]
    if {[llength $pin_net] != 1 || $pin_net ne $source_net} {
        lappend ::failures "$pin_name is not driven by $expected_source"
    }
}

foreach name {
    processing_system7_0
    ps_axi3_lite_bridge_0
    generator_accelerator_0
    dma_ctrl_protocol_converter
    axi_dma_0
    dma_mem_smartconnect
    axis_job_fifo
    axis_result_fifo
    rst_ps7_0_100M
    rst_ps7_0_150M
    dma_irq_concat
} {
    check_cell $name
}

if {[llength [get_bd_cells -quiet axi_debug_system_ila]] != 0} {
    lappend failures "production BD still contains axi_debug_system_ila"
}

set ps [get_bd_cells -quiet processing_system7_0]
if {[llength $ps] == 1} {
    foreach {property expected} {
        CONFIG.PCW_USE_M_AXI_GP0 1
        CONFIG.PCW_USE_M_AXI_GP1 1
        CONFIG.PCW_USE_S_AXI_HP0 1
        CONFIG.PCW_FPGA_FCLK0_ENABLE 1
        CONFIG.PCW_FPGA_FCLK1_ENABLE 1
    } {
        if {[get_property $property $ps] ne $expected} {
            lappend failures "$property is not $expected"
        }
    }
    set fclk1_mhz [get_property CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $ps]
    if {![string match "150.*" $fclk1_mhz]} {
        lappend failures "FCLK1 is not configured for 150 MHz (got $fclk1_mhz)"
    }
}

check_intf_link processing_system7_0/M_AXI_GP0 ps_axi3_lite_bridge_0/S_AXI
check_intf_link ps_axi3_lite_bridge_0/M_AXI generator_accelerator_0/s_axi
check_intf_link processing_system7_0/M_AXI_GP1 dma_ctrl_protocol_converter/S_AXI
check_intf_link dma_ctrl_protocol_converter/M_AXI axi_dma_0/S_AXI_LITE
check_intf_link axi_dma_0/M_AXIS_MM2S axis_job_fifo/S_AXIS
check_intf_link axis_job_fifo/M_AXIS generator_accelerator_0/s_axis_job
check_intf_link generator_accelerator_0/m_axis_result axis_result_fifo/S_AXIS
check_intf_link axis_result_fifo/M_AXIS axi_dma_0/S_AXIS_S2MM
check_intf_link axi_dma_0/M_AXI_MM2S dma_mem_smartconnect/S00_AXI
check_intf_link axi_dma_0/M_AXI_S2MM dma_mem_smartconnect/S01_AXI
check_intf_link dma_mem_smartconnect/M00_AXI processing_system7_0/S_AXI_HP0

foreach pin {
    processing_system7_0/M_AXI_GP0_ACLK
    processing_system7_0/M_AXI_GP1_ACLK
    ps_axi3_lite_bridge_0/aclk
    dma_ctrl_protocol_converter/aclk
    axi_dma_0/s_axi_lite_aclk
    axis_job_fifo/m_axis_aclk
    axis_result_fifo/s_axis_aclk
    generator_accelerator_0/s_axi_aclk
} {
    check_pin_net $pin processing_system7_0/FCLK_CLK0
}

foreach pin {
    processing_system7_0/S_AXI_HP0_ACLK
    axi_dma_0/m_axi_mm2s_aclk
    axi_dma_0/m_axi_s2mm_aclk
    axis_job_fifo/s_axis_aclk
    axis_result_fifo/m_axis_aclk
    dma_mem_smartconnect/aclk
} {
    check_pin_net $pin processing_system7_0/FCLK_CLK1
}

check_pin_net dma_irq_concat/dout processing_system7_0/IRQ_F2P
check_pin_net axi_dma_0/mm2s_introut dma_irq_concat/In0
check_pin_net axi_dma_0/s2mm_introut dma_irq_concat/In1
check_pin_net rst_ps7_0_150M/ext_reset_in processing_system7_0/FCLK_RESET1_N
foreach pin {
    dma_ctrl_protocol_converter/aresetn
    generator_accelerator_0/s_axi_aresetn
    axi_dma_0/axi_resetn
    axis_result_fifo/s_axis_aresetn
} {
    check_pin_net $pin rst_ps7_0_100M/peripheral_aresetn
}
foreach pin {
    axis_job_fifo/s_axis_aresetn
    dma_mem_smartconnect/aresetn
} {
    check_pin_net $pin rst_ps7_0_150M/peripheral_aresetn
}

set dma [get_bd_cells -quiet axi_dma_0]
if {[llength $dma] == 1} {
    foreach {property expected} {
        CONFIG.c_include_sg 0
        CONFIG.c_include_mm2s_dre 0
        CONFIG.c_include_s2mm_dre 0
        CONFIG.c_m_axi_mm2s_data_width 128
        CONFIG.c_m_axi_s2mm_data_width 128
        CONFIG.c_m_axis_mm2s_tdata_width 128
        CONFIG.c_s_axis_s2mm_tdata_width 128
        CONFIG.c_mm2s_burst_size 16
        CONFIG.c_s2mm_burst_size 16
        CONFIG.c_sg_length_width 23
    } {
        if {[get_property $property $dma] ne $expected} {
            lappend failures "$property is not $expected"
        }
    }
}

foreach fifo_name {axis_job_fifo axis_result_fifo} {
    set fifo [get_bd_cells -quiet $fifo_name]
    if {[llength $fifo] == 1} {
        foreach {property expected} {
            CONFIG.TDATA_NUM_BYTES 16
            CONFIG.HAS_TKEEP 1
            CONFIG.HAS_TLAST 1
            CONFIG.IS_ACLK_ASYNC 1
        } {
            if {[get_property $property $fifo] ne $expected} {
                lappend failures "$fifo_name $property is not $expected"
            }
        }
    }
}

set dma_segment [get_bd_addr_segs -quiet \
    processing_system7_0/Data/SEG_axi_dma_0_Reg]
if {[llength $dma_segment] != 1} {
    lappend failures "missing AXI DMA register address segment"
} elseif {[get_property OFFSET $dma_segment] ne "0x80400000"} {
    lappend failures "AXI DMA register base is not 0x80400000"
}

set legacy_segment [get_bd_addr_segs -quiet \
    processing_system7_0/Data/SEG_ps_axi3_lite_bridge_0_reg0]
if {[llength $legacy_segment] != 1 ||
    [get_property OFFSET $legacy_segment] ne "0x43C00000"} {
    lappend failures "legacy accelerator base 0x43C00000 was not preserved"
}

foreach segment_name {
    axi_dma_0/Data_MM2S/SEG_processing_system7_0_HP0_DDR_LOWOCM
    axi_dma_0/Data_S2MM/SEG_processing_system7_0_HP0_DDR_LOWOCM
} {
    if {[llength [get_bd_addr_segs -quiet $segment_name]] != 1} {
        lappend failures "missing HP0 DDR mapping $segment_name"
    }
}

if {[llength $failures] != 0} {
    foreach failure $failures {puts "CHECK_FAIL: $failure"}
    error "DMA batch BD check failed with [llength $failures] issue(s)"
}

validate_bd_design
puts "DMA_BATCH_BD_CHECK_PASSED"
close_project
exit
