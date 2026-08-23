set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir FPGA.xpr]
set bd_file [file join $script_dir FPGA.srcs sources_1 bd system system.bd]
set lcd_xdc [file normalize [file join $script_dir .. constraints \
                             Z15_LCD_800x480.xdc]]

if {[current_project -quiet] eq ""} {
    open_project $project_file
}
update_ip_catalog
open_bd_design $bd_file
current_bd_design system

if {[llength [get_files -quiet *Z15_LCD_800x480.xdc]] == 0} {
    add_files -fileset constrs_1 -norecurse $lcd_xdc
}

set ps processing_system7_0
set legacy_bridge ps_axi3_lite_bridge_0
set accel generator_accelerator_0
set build_mode release
if {[info exists ::env(BUILD_MODE)]} {
    set build_mode [string tolower $::env(BUILD_MODE)]
}
if {$build_mode ni {debug release}} {
    error "BUILD_MODE must be debug or release (got $build_mode)"
}

foreach required [list $ps $legacy_bridge rst_ps7_0_100M reset_const_0 reset_const_1] {
    if {[llength [get_bd_cells -quiet $required]] != 1} {
        error "Required legacy cell is missing: $required"
    }
}

# Remove the large debug-only ILA and replace the locked accelerator instance
# with the newly packaged AXI-Lite + dual AXI-Stream version.
foreach old_cell {
    axi_debug_system_ila
    generator_accelerator_0
    ps_axi3_lite_bridge_dma
    dma_ctrl_protocol_converter
    axi_dma_0
    dma_mm2s_dwidth
    dma_s2mm_dwidth
    dma_mem_smartconnect
    dma_mem_interconnect
    axis_job_fifo
    axis_result_fifo
    accelerator_clock_wizard
    legacy_core_clock_converter
    dma_ctrl_interconnect
    accelerator_debug_ila
    clock_profile_const
    rst_accelerator_core
    rst_ps7_0_33M
    rst_ps7_0_150M
    rst_ps7_0_125M
    dma_irq_concat
} {
    set object [get_bd_cells -quiet $old_cell]
    if {[llength $object] != 0} {
        delete_bd_objs $object
    }
}

set accel [create_bd_cell -type ip \
    -vlnv xilinx.com:user:generator_accelerator_top:1.0 \
    generator_accelerator_0]

set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_M_AXI_GP1 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_CLK1_PORT {1} \
    CONFIG.PCW_EN_CLK2_PORT {1} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE {1} \
    CONFIG.PCW_FPGA_FCLK2_ENABLE {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {125.000000} \
    CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ {33.000000} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_RST1_PORT {1} \
    CONFIG.PCW_EN_RST2_PORT {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
] [get_bd_cells $ps]

set dma_bridge [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_protocol_converter:2.1 \
    dma_ctrl_protocol_converter]
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI3} \
    CONFIG.MI_PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
] $dma_bridge

set ctrl_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 \
    dma_ctrl_interconnect]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_ic

set core_clock [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:clk_wiz:6.0 \
    accelerator_clock_wizard]
set_property -dict [list \
    CONFIG.USE_DYN_RECONFIG {true} \
    CONFIG.INTERFACE_SELECTION {Enable_AXI} \
    CONFIG.PRIM_IN_FREQ {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000} \
] $core_clock

set legacy_clock_converter [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_clock_converter:2.1 \
    legacy_core_clock_converter]
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4LITE} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.DATA_WIDTH {32} \
    CONFIG.ACLK_ASYNC {1} \
] $legacy_clock_converter

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s_dre {0} \
    CONFIG.c_include_s2mm_dre {0} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_sg_length_width {23} \
] $dma

# AXI DMA 7.1 requires its memory-mapped ports to be at least as wide as the
# configured 128-bit stream.  Convert each DDR channel explicitly to the
# Zynq-7000 HP0 port's native 64-bit width instead of relying on an implicit
# SmartConnect conversion.
set mm2s_dwidth [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 dma_mm2s_dwidth]
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.SI_DATA_WIDTH {128} \
    CONFIG.MI_DATA_WIDTH {64} \
] $mm2s_dwidth

set s2mm_dwidth [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 dma_s2mm_dwidth]
set_property -dict [list \
    CONFIG.PROTOCOL {AXI4} \
    CONFIG.ADDR_WIDTH {32} \
    CONFIG.SI_DATA_WIDTH {128} \
    CONFIG.MI_DATA_WIDTH {64} \
] $s2mm_dwidth

set job_fifo [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_job_fifo]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {16} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.FIFO_DEPTH {512} \
    CONFIG.IS_ACLK_ASYNC {1} \
] $job_fifo

set result_fifo [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axis_data_fifo:2.0 axis_result_fifo]
set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {16} \
    CONFIG.HAS_TKEEP {1} \
    CONFIG.HAS_TLAST {1} \
    CONFIG.FIFO_DEPTH {512} \
    CONFIG.IS_ACLK_ASYNC {1} \
] $result_fifo

set mem_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 dma_mem_interconnect]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_ic

set rst125 [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_125M]
set rst33 [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_33M]
set rst_core [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_accelerator_core]

set irq_concat [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconcat:2.1 dma_irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {2}] $irq_concat

# Preserve the original GP0 register path and add GP1 as a separate DMA
# control path.  A Xilinx protocol converter keeps the DMA visible to HSI so
# Vitis can bind the axidma driver and generate its configuration table.
connect_bd_intf_net [get_bd_intf_pins $legacy_bridge/M_AXI] \
    [get_bd_intf_pins $legacy_clock_converter/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $legacy_clock_converter/M_AXI] \
    [get_bd_intf_pins $accel/s_axi]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP1] \
    [get_bd_intf_pins $dma_bridge/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma_bridge/M_AXI] \
    [get_bd_intf_pins $ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $ctrl_ic/M00_AXI] \
    [get_bd_intf_pins $dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins $ctrl_ic/M01_AXI] \
    [get_bd_intf_pins $core_clock/s_axi_lite]

# AXI4-Stream task/result path, fixed at 128 bits (16 bytes per beat).
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] \
    [get_bd_intf_pins $job_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $job_fifo/M_AXIS] \
    [get_bd_intf_pins $accel/s_axis_job]
connect_bd_intf_net [get_bd_intf_pins $accel/m_axis_result] \
    [get_bd_intf_pins $result_fifo/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins $result_fifo/M_AXIS] \
    [get_bd_intf_pins $dma/S_AXIS_S2MM]

# Both 128-bit DMA memory masters are converted to native 64-bit HP0 AXI4,
# then share the PS DDR port through a two-input AXI Interconnect.  The complete
# memory fabric runs at the documented 125 MHz Ethernet-compatible fallback.
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_MM2S] \
    [get_bd_intf_pins $mm2s_dwidth/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXI_S2MM] \
    [get_bd_intf_pins $s2mm_dwidth/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $mm2s_dwidth/M_AXI] \
    [get_bd_intf_pins $mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $s2mm_dwidth/M_AXI] \
    [get_bd_intf_pins $mem_ic/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins $mem_ic/M00_AXI] \
    [get_bd_intf_pins $ps/S_AXI_HP0]

set clk100 [get_bd_pins $ps/FCLK_CLK0]
set clk125 [get_bd_pins $ps/FCLK_CLK1]
set clk33 [get_bd_pins $ps/FCLK_CLK2]
set accel_clk [get_bd_pins $core_clock/clk_out1]

connect_bd_net $clk100 \
    [get_bd_pins $ps/M_AXI_GP0_ACLK] \
    [get_bd_pins $ps/M_AXI_GP1_ACLK] \
    [get_bd_pins $legacy_bridge/aclk] \
    [get_bd_pins $dma_bridge/aclk] \
    [get_bd_pins $ctrl_ic/ACLK] \
    [get_bd_pins $ctrl_ic/S00_ACLK] \
    [get_bd_pins $ctrl_ic/M00_ACLK] \
    [get_bd_pins $ctrl_ic/M01_ACLK] \
    [get_bd_pins $core_clock/clk_in1] \
    [get_bd_pins $core_clock/s_axi_aclk] \
    [get_bd_pins $legacy_clock_converter/s_axi_aclk] \
    [get_bd_pins $dma/s_axi_lite_aclk] \
    [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]

connect_bd_net $accel_clk \
    [get_bd_pins $legacy_clock_converter/m_axi_aclk] \
    [get_bd_pins $accel/s_axi_aclk] \
    [get_bd_pins $job_fifo/m_axis_aclk] \
    [get_bd_pins $result_fifo/s_axis_aclk] \
    [get_bd_pins $rst_core/slowest_sync_clk]

connect_bd_net $clk33 [get_bd_pins $rst33/slowest_sync_clk]
connect_bd_net $clk33 [get_bd_pins $accel/lcd_pixel_clk]

connect_bd_net $clk125 \
    [get_bd_pins $ps/S_AXI_HP0_ACLK] \
    [get_bd_pins $dma/m_axi_mm2s_aclk] \
    [get_bd_pins $dma/m_axi_s2mm_aclk] \
    [get_bd_pins $job_fifo/s_axis_aclk] \
    [get_bd_pins $result_fifo/m_axis_aclk] \
    [get_bd_pins $mm2s_dwidth/s_axi_aclk] \
    [get_bd_pins $s2mm_dwidth/s_axi_aclk] \
    [get_bd_pins $mem_ic/ACLK] \
    [get_bd_pins $mem_ic/S00_ACLK] \
    [get_bd_pins $mem_ic/S01_ACLK] \
    [get_bd_pins $mem_ic/M00_ACLK] \
    [get_bd_pins $rst125/slowest_sync_clk]

# Use the FCLK1 reset source associated with the 125 MHz memory domain.
connect_bd_net [get_bd_pins $ps/FCLK_RESET1_N] \
    [get_bd_pins $rst125/ext_reset_in]
connect_bd_net [get_bd_pins $ps/FCLK_RESET2_N] \
    [get_bd_pins $rst33/ext_reset_in]
connect_bd_net [get_bd_pins $ps/FCLK_RESET0_N] \
    [get_bd_pins $rst_core/ext_reset_in]
# This newly created proc_sys_reset instance has C_AUX_RESET_HIGH=0 in
# Vivado 2019.2.  Tie aux_reset_in high (inactive); tying it to reset_const_0
# permanently held the complete DMA/HP0 domain in reset on hardware.
connect_bd_net [get_bd_pins reset_const_0/dout] \
    [get_bd_pins $rst125/mb_debug_sys_rst] \
    [get_bd_pins $rst33/mb_debug_sys_rst] \
    [get_bd_pins $rst_core/mb_debug_sys_rst]
connect_bd_net [get_bd_pins reset_const_1/dout] \
    [get_bd_pins $rst125/aux_reset_in] \
    [get_bd_pins $rst125/dcm_locked] \
    [get_bd_pins $rst33/aux_reset_in] \
    [get_bd_pins $rst33/dcm_locked] \
    [get_bd_pins $rst_core/aux_reset_in]
connect_bd_net [get_bd_pins $core_clock/locked] \
    [get_bd_pins $rst_core/dcm_locked]

set reset100n [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
set reset125n [get_bd_pins $rst125/peripheral_aresetn]
set reset_core_n [get_bd_pins $rst_core/peripheral_aresetn]
set reset33n [get_bd_pins $rst33/peripheral_aresetn]
connect_bd_net $reset100n \
    [get_bd_pins $legacy_bridge/aresetn] \
    [get_bd_pins $dma_bridge/aresetn] \
    [get_bd_pins $ctrl_ic/ARESETN] \
    [get_bd_pins $ctrl_ic/S00_ARESETN] \
    [get_bd_pins $ctrl_ic/M00_ARESETN] \
    [get_bd_pins $ctrl_ic/M01_ARESETN] \
    [get_bd_pins $core_clock/s_axi_aresetn] \
    [get_bd_pins $legacy_clock_converter/s_axi_aresetn] \
    [get_bd_pins $dma/axi_resetn]

connect_bd_net $reset_core_n \
    [get_bd_pins $legacy_clock_converter/m_axi_aresetn] \
    [get_bd_pins $accel/s_axi_aresetn] \
    [get_bd_pins $result_fifo/s_axis_aresetn]
connect_bd_net $reset125n \
    [get_bd_pins $job_fifo/s_axis_aresetn] \
    [get_bd_pins $mm2s_dwidth/s_axi_aresetn] \
    [get_bd_pins $s2mm_dwidth/s_axi_aresetn] \
    [get_bd_pins $mem_ic/ARESETN] \
    [get_bd_pins $mem_ic/S00_ARESETN] \
    [get_bd_pins $mem_ic/S01_ARESETN] \
    [get_bd_pins $mem_ic/M00_ARESETN]

connect_bd_net $reset33n \
    [get_bd_pins $accel/lcd_aresetn]
connect_bd_net [get_bd_pins reset_const_1/dout] \
    [get_bd_pins $accel/lcd_clock_locked]

# RGB LCD and HDMI-IN share the 24 color pins on this board.  Only the LCD
# outputs are externalized here; an HDMI-IN design must remove these ports.
foreach lcd_port {lcd_rgb lcd_hs lcd_vs lcd_de lcd_clk lcd_rst lcd_bl} {
    set stale [get_bd_ports -quiet $lcd_port]
    if {[llength $stale] != 0} {
        delete_bd_objs $stale
    }
    set lcd_pin [get_bd_pins -quiet $accel/$lcd_port]
    if {[llength $lcd_pin] != 1} {
        error "LCD output pin is missing from packaged IP: $lcd_port"
    }
    make_bd_pins_external $lcd_pin
    set lcd_net [get_bd_nets -quiet -of_objects $lcd_pin]
    set external [get_bd_ports -quiet -of_objects $lcd_net]
    if {[llength $external] != 1} {
        error "Failed to externalize LCD output pin: $lcd_port"
    }
    set_property name $lcd_port $external
}

if {$build_mode eq "debug"} {
    set ila [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 \
        accelerator_debug_ila]
    set_property -dict [list \
        CONFIG.C_MONITOR_TYPE {Native} \
        CONFIG.C_ENABLE_ILA_AXI_MON {false} \
        CONFIG.C_NUM_OF_PROBES {6} \
        CONFIG.C_PROBE0_WIDTH {7} \
        CONFIG.C_PROBE1_WIDTH {3} \
        CONFIG.C_PROBE2_WIDTH {3} \
        CONFIG.C_PROBE3_WIDTH {3} \
        CONFIG.C_PROBE4_WIDTH {6} \
        CONFIG.C_PROBE5_WIDTH {2} \
    ] $ila
    set profile [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 \
        clock_profile_const]
    set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0}] $profile
    connect_bd_net $accel_clk [get_bd_pins $ila/clk]
    connect_bd_net [get_bd_pins $accel/debug_queue_occupancy] \
        [get_bd_pins $ila/probe0]
    connect_bd_net [get_bd_pins $accel/engine_start] \
        [get_bd_pins $ila/probe1]
    connect_bd_net [get_bd_pins $accel/engine_busy] \
        [get_bd_pins $ila/probe2]
    connect_bd_net [get_bd_pins $accel/engine_done] \
        [get_bd_pins $ila/probe3]
    connect_bd_net [get_bd_pins $accel/debug_active_sequence] \
        [get_bd_pins $ila/probe4]
    connect_bd_net [get_bd_pins $profile/dout] [get_bd_pins $ila/probe5]
}

connect_bd_net [get_bd_pins $dma/mm2s_introut] \
    [get_bd_pins $irq_concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] \
    [get_bd_pins $irq_concat/In1]
connect_bd_net [get_bd_pins $irq_concat/dout] \
    [get_bd_pins $ps/IRQ_F2P]

# Control/register maps.  Keep the accelerator at its proven legacy base and
# place AXI DMA inside the PS GP1 aperture at 0x8040_0000.
assign_bd_address -offset 0x43C00000 -range 0x00040000 \
    -target_address_space [get_bd_addr_spaces $legacy_bridge/M_AXI] \
    [get_bd_addr_segs $accel/s_axi/reg0] -force
assign_bd_address -offset 0x80400000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] \
    [get_bd_addr_segs $dma/S_AXI_LITE/Reg] -force
assign_bd_address -offset 0x80410000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces $ps/Data] \
    [get_bd_addr_segs $core_clock/s_axi_lite/reg0] -force

# Expose the PS DDR address window to both DMA data movers.
foreach dma_space [list \
    [get_bd_addr_spaces $dma/Data_MM2S] \
    [get_bd_addr_spaces $dma/Data_S2MM] \
] {
    assign_bd_address -target_address_space $dma_space \
        [get_bd_addr_segs $ps/S_AXI_HP0/HP0_DDR_LOWOCM]
}

regenerate_bd_layout
validate_bd_design
save_bd_design

# Vivado 2019.2 can retain stale source-direction metadata after cells are
# deleted and recreated in one BD session.  Reopen the saved design before
# target generation so proc_sys_reset outputs and DMA interrupts are not
# incorrectly grounded in the generated wrapper.
close_bd_design [get_bd_designs system]
open_bd_design $bd_file
validate_bd_design
save_bd_design
set bd_object [get_files -quiet $bd_file]
reset_target all $bd_object
generate_target all $bd_object
puts "DMA_BATCH_BD_CREATED"
puts "BUILD_MODE=$build_mode"
puts "RUNTIME_CLOCK_PROFILES_MHZ=50,100,150"
if {![info exists ::MOL_DMA_KEEP_PROJECT_OPEN] ||
    !$::MOL_DMA_KEEP_PROJECT_OPEN} {
    close_project
    exit
}
