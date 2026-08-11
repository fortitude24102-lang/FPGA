set script_dir [file dirname [file normalize [info script]]]
set project_file [file join $script_dir FPGA.xpr]
set bd_file [file join $script_dir FPGA.srcs sources_1 bd system system.bd]

if {[current_project -quiet] eq ""} {
    open_project $project_file
}
update_ip_catalog
open_bd_design $bd_file
current_bd_design system

set ps processing_system7_0
set legacy_bridge ps_axi3_lite_bridge_0
set accel generator_accelerator_0

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
    rst_ps7_0_150M
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
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_FPGA_FCLK1_ENABLE {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {150.000000} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_RST1_PORT {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
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

set rst150 [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ps7_0_150M]

set irq_concat [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconcat:2.1 dma_irq_concat]
set_property -dict [list CONFIG.NUM_PORTS {2}] $irq_concat

# Preserve the original GP0 register path and add GP1 as a separate DMA
# control path.  A Xilinx protocol converter keeps the DMA visible to HSI so
# Vitis can bind the axidma driver and generate its configuration table.
connect_bd_intf_net [get_bd_intf_pins $legacy_bridge/M_AXI] \
    [get_bd_intf_pins $accel/s_axi]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_GP1] \
    [get_bd_intf_pins $dma_bridge/S_AXI]
connect_bd_intf_net [get_bd_intf_pins $dma_bridge/M_AXI] \
    [get_bd_intf_pins $dma/S_AXI_LITE]

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
# memory fabric runs at 150 MHz.
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
set clk150 [get_bd_pins $ps/FCLK_CLK1]

connect_bd_net $clk100 \
    [get_bd_pins $ps/M_AXI_GP0_ACLK] \
    [get_bd_pins $ps/M_AXI_GP1_ACLK] \
    [get_bd_pins $legacy_bridge/aclk] \
    [get_bd_pins $dma_bridge/aclk] \
    [get_bd_pins $accel/s_axi_aclk] \
    [get_bd_pins $dma/s_axi_lite_aclk] \
    [get_bd_pins $job_fifo/m_axis_aclk] \
    [get_bd_pins $result_fifo/s_axis_aclk] \
    [get_bd_pins rst_ps7_0_100M/slowest_sync_clk]

connect_bd_net $clk150 \
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
    [get_bd_pins $rst150/slowest_sync_clk]

# Use the FCLK1 reset source associated with the 150 MHz memory domain.
connect_bd_net [get_bd_pins $ps/FCLK_RESET1_N] \
    [get_bd_pins $rst150/ext_reset_in]
# This newly created proc_sys_reset instance has C_AUX_RESET_HIGH=0 in
# Vivado 2019.2.  Tie aux_reset_in high (inactive); tying it to reset_const_0
# permanently held the complete 150 MHz DMA/HP0 domain in reset on hardware.
connect_bd_net [get_bd_pins reset_const_0/dout] \
    [get_bd_pins $rst150/mb_debug_sys_rst]
connect_bd_net [get_bd_pins reset_const_1/dout] \
    [get_bd_pins $rst150/aux_reset_in] \
    [get_bd_pins $rst150/dcm_locked]

set reset100n [get_bd_pins rst_ps7_0_100M/peripheral_aresetn]
set reset150n [get_bd_pins $rst150/peripheral_aresetn]
connect_bd_net $reset100n \
    [get_bd_pins $legacy_bridge/aresetn] \
    [get_bd_pins $dma_bridge/aresetn] \
    [get_bd_pins $accel/s_axi_aresetn] \
    [get_bd_pins $dma/axi_resetn] \
    [get_bd_pins $result_fifo/s_axis_aresetn]
connect_bd_net $reset150n \
    [get_bd_pins $job_fifo/s_axis_aresetn] \
    [get_bd_pins $mm2s_dwidth/s_axi_aresetn] \
    [get_bd_pins $s2mm_dwidth/s_axi_aresetn] \
    [get_bd_pins $mem_ic/ARESETN] \
    [get_bd_pins $mem_ic/S00_ARESETN] \
    [get_bd_pins $mem_ic/S01_ARESETN] \
    [get_bd_pins $mem_ic/M00_ARESETN]

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
if {![info exists ::MOL_DMA_KEEP_PROJECT_OPEN] ||
    !$::MOL_DMA_KEEP_PROJECT_OPEN} {
    close_project
    exit
}
