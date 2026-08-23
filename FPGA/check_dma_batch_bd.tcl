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

set build_mode release
if {[info exists ::env(BUILD_MODE)]} {
    set build_mode [string tolower $::env(BUILD_MODE)]
}
if {$build_mode ni {debug release}} {
    error "BUILD_MODE must be debug or release (got $build_mode)"
}

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

proc check_external_pin {pin_name port_name} {
    set pin [get_bd_pins -quiet $pin_name]
    set port [get_bd_ports -quiet $port_name]
    if {[llength $pin] != 1 || [llength $port] != 1} {
        lappend ::failures "missing external connection $pin_name -> $port_name"
        return
    }
    set pin_net [get_bd_nets -quiet -of_objects $pin]
    set port_net [get_bd_nets -quiet -of_objects $port]
    if {[llength $pin_net] != 1 || $pin_net ne $port_net} {
        lappend ::failures "$pin_name is not connected to port $port_name"
    }
}

foreach name {
    processing_system7_0
    ps_axi3_lite_bridge_0
    generator_accelerator_0
    dma_ctrl_protocol_converter
    dma_ctrl_interconnect
    axi_dma_0
    dma_mm2s_dwidth
    dma_s2mm_dwidth
    dma_mem_interconnect
    axis_job_fifo
    axis_result_fifo
    accelerator_clock_wizard
    legacy_core_clock_converter
    rst_ps7_0_100M
    rst_ps7_0_125M
    rst_ps7_0_33M
    rst_accelerator_core
    dma_irq_concat
} {
    check_cell $name
}

set ila_cells [get_bd_cells -quiet -hierarchical -filter {VLNV =~ "xilinx.com:ip:ila:*"}]
if {$build_mode eq "release" && [llength $ila_cells] != 0} {
    lappend failures "release BD contains ILA: $ila_cells"
}
if {$build_mode eq "debug"} {
    if {[llength $ila_cells] != 1 ||
        [llength [get_bd_cells -quiet accelerator_debug_ila]] != 1} {
        lappend failures "debug BD must contain exactly accelerator_debug_ila"
    }
}

set ps [get_bd_cells -quiet processing_system7_0]
if {[llength $ps] == 1} {
    foreach {property expected} {
        CONFIG.PCW_USE_M_AXI_GP0 1
        CONFIG.PCW_USE_M_AXI_GP1 1
        CONFIG.PCW_USE_S_AXI_HP0 1
        CONFIG.PCW_FPGA_FCLK0_ENABLE 1
        CONFIG.PCW_FPGA_FCLK1_ENABLE 1
        CONFIG.PCW_FPGA_FCLK2_ENABLE 1
    } {
        if {[get_property $property $ps] ne $expected} {
            lappend failures "$property is not $expected"
        }
    }
    set fclk1_mhz [get_property CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ $ps]
    if {![string match "125.*" $fclk1_mhz]} {
        lappend failures "FCLK1 is not configured for 125 MHz (got $fclk1_mhz)"
    }
    set fclk0_mhz [get_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $ps]
    if {![string match "100.*" $fclk0_mhz]} {
        lappend failures "FCLK0 is not configured for 100 MHz (got $fclk0_mhz)"
    }
    set fclk2_mhz [get_property CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ $ps]
    if {![string match "33.*" $fclk2_mhz]} {
        lappend failures "FCLK2 is not configured for 33 MHz (got $fclk2_mhz)"
    }
}

check_intf_link processing_system7_0/M_AXI_GP0 ps_axi3_lite_bridge_0/S_AXI
check_intf_link ps_axi3_lite_bridge_0/M_AXI legacy_core_clock_converter/S_AXI
check_intf_link legacy_core_clock_converter/M_AXI generator_accelerator_0/s_axi
check_intf_link processing_system7_0/M_AXI_GP1 dma_ctrl_protocol_converter/S_AXI
check_intf_link dma_ctrl_protocol_converter/M_AXI dma_ctrl_interconnect/S00_AXI
check_intf_link dma_ctrl_interconnect/M00_AXI axi_dma_0/S_AXI_LITE
check_intf_link dma_ctrl_interconnect/M01_AXI accelerator_clock_wizard/s_axi_lite
check_intf_link axi_dma_0/M_AXIS_MM2S axis_job_fifo/S_AXIS
check_intf_link axis_job_fifo/M_AXIS generator_accelerator_0/s_axis_job
check_intf_link generator_accelerator_0/m_axis_result axis_result_fifo/S_AXIS
check_intf_link axis_result_fifo/M_AXIS axi_dma_0/S_AXIS_S2MM
check_intf_link axi_dma_0/M_AXI_MM2S dma_mm2s_dwidth/S_AXI
check_intf_link axi_dma_0/M_AXI_S2MM dma_s2mm_dwidth/S_AXI
check_intf_link dma_mm2s_dwidth/M_AXI dma_mem_interconnect/S00_AXI
check_intf_link dma_s2mm_dwidth/M_AXI dma_mem_interconnect/S01_AXI
check_intf_link dma_mem_interconnect/M00_AXI processing_system7_0/S_AXI_HP0

foreach pin {
    processing_system7_0/M_AXI_GP0_ACLK
    processing_system7_0/M_AXI_GP1_ACLK
    ps_axi3_lite_bridge_0/aclk
    dma_ctrl_protocol_converter/aclk
    dma_ctrl_interconnect/ACLK
    dma_ctrl_interconnect/S00_ACLK
    dma_ctrl_interconnect/M00_ACLK
    dma_ctrl_interconnect/M01_ACLK
    axi_dma_0/s_axi_lite_aclk
    accelerator_clock_wizard/clk_in1
    accelerator_clock_wizard/s_axi_aclk
    legacy_core_clock_converter/s_axi_aclk
} {
    check_pin_net $pin processing_system7_0/FCLK_CLK0
}

check_pin_net rst_ps7_0_33M/slowest_sync_clk processing_system7_0/FCLK_CLK2
check_pin_net rst_ps7_0_33M/ext_reset_in processing_system7_0/FCLK_RESET2_N
check_pin_net generator_accelerator_0/lcd_pixel_clk processing_system7_0/FCLK_CLK2
check_pin_net generator_accelerator_0/lcd_aresetn rst_ps7_0_33M/peripheral_aresetn
check_pin_net generator_accelerator_0/lcd_clock_locked reset_const_1/dout
foreach lcd_port {lcd_rgb lcd_hs lcd_vs lcd_de lcd_clk lcd_rst lcd_bl} {
    check_external_pin generator_accelerator_0/$lcd_port $lcd_port
}
set lcd_rgb [get_bd_ports -quiet lcd_rgb]
if {[llength $lcd_rgb] == 1 &&
    ([get_property LEFT $lcd_rgb] ne "23" ||
     [get_property RIGHT $lcd_rgb] ne "0")} {
    lappend failures "lcd_rgb external port is not 24 bits"
}
if {[llength [get_files -quiet *Z15_LCD_800x480.xdc]] != 1} {
    lappend failures "Z15 LCD pin constraint file is missing"
}

foreach pin {
    accelerator_clock_wizard/clk_out1
    legacy_core_clock_converter/m_axi_aclk
    generator_accelerator_0/s_axi_aclk
    axis_job_fifo/m_axis_aclk
    axis_result_fifo/s_axis_aclk
    rst_accelerator_core/slowest_sync_clk
} {
    check_pin_net $pin accelerator_clock_wizard/clk_out1
}
check_pin_net rst_accelerator_core/dcm_locked accelerator_clock_wizard/locked

foreach pin {
    processing_system7_0/S_AXI_HP0_ACLK
    axi_dma_0/m_axi_mm2s_aclk
    axi_dma_0/m_axi_s2mm_aclk
    axis_job_fifo/s_axis_aclk
    axis_result_fifo/m_axis_aclk
    dma_mm2s_dwidth/s_axi_aclk
    dma_s2mm_dwidth/s_axi_aclk
    dma_mem_interconnect/ACLK
    dma_mem_interconnect/S00_ACLK
    dma_mem_interconnect/S01_ACLK
    dma_mem_interconnect/M00_ACLK
} {
    check_pin_net $pin processing_system7_0/FCLK_CLK1
}

check_pin_net dma_irq_concat/dout processing_system7_0/IRQ_F2P
check_pin_net axi_dma_0/mm2s_introut dma_irq_concat/In0
check_pin_net axi_dma_0/s2mm_introut dma_irq_concat/In1
check_pin_net rst_ps7_0_125M/ext_reset_in processing_system7_0/FCLK_RESET1_N
check_pin_net rst_ps7_0_125M/aux_reset_in reset_const_1/dout
set rst125_cell [get_bd_cells -quiet rst_ps7_0_125M]
if {[llength $rst125_cell] == 1 &&
    [get_property CONFIG.C_AUX_RESET_HIGH $rst125_cell] ne "0"} {
    lappend failures "rst_ps7_0_125M auxiliary reset is not active-low"
}
foreach pin {
    dma_ctrl_protocol_converter/aresetn
    dma_ctrl_interconnect/ARESETN
    dma_ctrl_interconnect/S00_ARESETN
    dma_ctrl_interconnect/M00_ARESETN
    dma_ctrl_interconnect/M01_ARESETN
    axi_dma_0/axi_resetn
    accelerator_clock_wizard/s_axi_aresetn
    legacy_core_clock_converter/s_axi_aresetn
} {
    check_pin_net $pin rst_ps7_0_100M/peripheral_aresetn
}
foreach pin {
    legacy_core_clock_converter/m_axi_aresetn
    generator_accelerator_0/s_axi_aresetn
    axis_result_fifo/s_axis_aresetn
} {
    check_pin_net $pin rst_accelerator_core/peripheral_aresetn
}
foreach pin {
    axis_job_fifo/s_axis_aresetn
    dma_mm2s_dwidth/s_axi_aresetn
    dma_s2mm_dwidth/s_axi_aresetn
    dma_mem_interconnect/ARESETN
    dma_mem_interconnect/S00_ARESETN
    dma_mem_interconnect/S01_ARESETN
    dma_mem_interconnect/M00_ARESETN
} {
    check_pin_net $pin rst_ps7_0_125M/peripheral_aresetn
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

foreach converter_name {dma_mm2s_dwidth dma_s2mm_dwidth} {
    set converter [get_bd_cells -quiet $converter_name]
    if {[llength $converter] == 1} {
        foreach {property expected} {
            CONFIG.PROTOCOL AXI4
            CONFIG.ADDR_WIDTH 32
            CONFIG.SI_DATA_WIDTH 128
            CONFIG.MI_DATA_WIDTH 64
        } {
            if {[get_property $property $converter] ne $expected} {
                lappend failures "$converter_name $property is not $expected"
            }
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

set wizard_segment [get_bd_addr_segs -quiet \
    processing_system7_0/Data/SEG_accelerator_clock_wizard_Reg]
if {[llength $wizard_segment] != 1} {
    lappend failures "missing Clocking Wizard register address segment"
} elseif {[get_property OFFSET $wizard_segment] ne "0x80410000"} {
    lappend failures "Clocking Wizard register base is not 0x80410000"
}

set wizard [get_bd_cells -quiet accelerator_clock_wizard]
if {[llength $wizard] == 1} {
    foreach {property expected} {
        CONFIG.USE_DYN_RECONFIG true
        CONFIG.INTERFACE_SELECTION Enable_AXI
        CONFIG.PRIM_IN_FREQ 100.000
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 100.000
    } {
        if {[get_property $property $wizard] ne $expected} {
            lappend failures "$property is not $expected"
        }
    }
}

if {$build_mode eq "debug"} {
    set ila [get_bd_cells -quiet accelerator_debug_ila]
    if {[llength $ila] == 1} {
        foreach {property expected} {
            CONFIG.C_MONITOR_TYPE Native
            CONFIG.C_ENABLE_ILA_AXI_MON false
            CONFIG.C_NUM_OF_PROBES 6
            CONFIG.C_PROBE0_WIDTH 7
            CONFIG.C_PROBE1_WIDTH 3
            CONFIG.C_PROBE2_WIDTH 3
            CONFIG.C_PROBE3_WIDTH 3
            CONFIG.C_PROBE4_WIDTH 6
            CONFIG.C_PROBE5_WIDTH 2
        } {
            if {[get_property $property $ila] ne $expected} {
                lappend failures "$property is not $expected"
            }
        }
    }
    check_pin_net accelerator_debug_ila/clk accelerator_clock_wizard/clk_out1
    foreach {probe source} {
        probe0 generator_accelerator_0/debug_queue_occupancy
        probe1 generator_accelerator_0/engine_start
        probe2 generator_accelerator_0/engine_busy
        probe3 generator_accelerator_0/engine_done
        probe4 generator_accelerator_0/debug_active_sequence
        probe5 clock_profile_const/dout
    } {
        check_pin_net accelerator_debug_ila/$probe $source
    }
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
