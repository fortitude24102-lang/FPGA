# Z15 on-board PL oscillator: 50 MHz.
create_clock -period 20.000 -waveform {0.000 10.000} \
    -name s_axi_aclk [get_ports s_axi_aclk]
