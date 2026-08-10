# ALINX Z15 (XC7Z015CLG485-2) board-level PL pin assignments.
#
# The RTL top currently names the physical board clock/reset ports after the
# AXI slave signals.  The mappings below therefore connect:
#   s_axi_aclk    <- SYS_CLK, 50 MHz oscillator, Bank 13 at 3.3 V
#   s_axi_aresetn <- board reset, active low, Bank 35 at 1.8 V

set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} \
    [get_ports s_axi_aclk]

set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS18} \
    [get_ports s_axi_aresetn]

# The remaining s_axi_* signals are a logical AXI4-Lite interface.  They must
# be connected inside the device to a Zynq PS AXI master (normally M_AXI_GP0),
# not assigned arbitrarily to external PL pins.
