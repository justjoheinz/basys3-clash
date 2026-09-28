## Pmod SD on header JA -- the upper of the two headers on the board's left edge.
## See constraints/PmodSD.xdc for the module's pinout and the timing exceptions.
##
##   Pmod pin  Signal  JA pin  FPGA pin
##   1         ~CS     JA1     J1
##   2         MOSI    JA2     L2
##   3         MISO    JA3     J2
##   4         SCK     JA4     G2
##   9         CD      JA9     H2
##   10        WP      JA10    G3
set_property -dict {PACKAGE_PIN J1 IOSTANDARD LVCMOS33} [get_ports sd_cs]
set_property -dict {PACKAGE_PIN L2 IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports sd_cd]
set_property -dict {PACKAGE_PIN G3 IOSTANDARD LVCMOS33} [get_ports sd_wp]
