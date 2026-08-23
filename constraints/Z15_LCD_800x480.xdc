# Z15 carrier RGB LCD output for the ATK-MD0430R 800x480 panel.
# The 24 RGB pins are shared with HDMI-IN.  Do not enable HDMI-IN while this
# constraint set is active.  lcd_rgb is packed as {red[7:0],green[7:0],blue[7:0]}.

set_property IOSTANDARD LVCMOS33 [get_ports {lcd_rgb[*] lcd_hs lcd_vs lcd_de lcd_bl lcd_clk lcd_rst}]
set_property SLEW FAST [get_ports {lcd_rgb[*] lcd_hs lcd_vs lcd_de lcd_clk}]
set_property DRIVE 8 [get_ports {lcd_rgb[*] lcd_hs lcd_vs lcd_de lcd_bl lcd_clk lcd_rst}]

set_property PACKAGE_PIN W17  [get_ports {lcd_rgb[0]}]
set_property PACKAGE_PIN Y17  [get_ports {lcd_rgb[1]}]
set_property PACKAGE_PIN U16  [get_ports {lcd_rgb[2]}]
set_property PACKAGE_PIN T16  [get_ports {lcd_rgb[3]}]
set_property PACKAGE_PIN Y13  [get_ports {lcd_rgb[4]}]
set_property PACKAGE_PIN Y12  [get_ports {lcd_rgb[5]}]
set_property PACKAGE_PIN AB14 [get_ports {lcd_rgb[6]}]
set_property PACKAGE_PIN AB13 [get_ports {lcd_rgb[7]}]

set_property PACKAGE_PIN AA20 [get_ports {lcd_rgb[8]}]
set_property PACKAGE_PIN AA19 [get_ports {lcd_rgb[9]}]
set_property PACKAGE_PIN W16  [get_ports {lcd_rgb[10]}]
set_property PACKAGE_PIN V16  [get_ports {lcd_rgb[11]}]
set_property PACKAGE_PIN AB19 [get_ports {lcd_rgb[12]}]
set_property PACKAGE_PIN AB18 [get_ports {lcd_rgb[13]}]
set_property PACKAGE_PIN V18  [get_ports {lcd_rgb[14]}]
set_property PACKAGE_PIN W18  [get_ports {lcd_rgb[15]}]

set_property PACKAGE_PIN W12  [get_ports {lcd_rgb[16]}]
set_property PACKAGE_PIN W13  [get_ports {lcd_rgb[17]}]
set_property PACKAGE_PIN V15  [get_ports {lcd_rgb[18]}]
set_property PACKAGE_PIN W15  [get_ports {lcd_rgb[19]}]
set_property PACKAGE_PIN V13  [get_ports {lcd_rgb[20]}]
set_property PACKAGE_PIN V14  [get_ports {lcd_rgb[21]}]
set_property PACKAGE_PIN AA14 [get_ports {lcd_rgb[22]}]
set_property PACKAGE_PIN AA15 [get_ports {lcd_rgb[23]}]

set_property PACKAGE_PIN A5 [get_ports lcd_hs]
set_property PACKAGE_PIN A4 [get_ports lcd_vs]
set_property PACKAGE_PIN U18 [get_ports lcd_de]
set_property PACKAGE_PIN A6 [get_ports lcd_bl]
set_property PACKAGE_PIN U17 [get_ports lcd_clk]
set_property PACKAGE_PIN A7 [get_ports lcd_rst]
