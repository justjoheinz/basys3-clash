## Pmod SD on header JC -- the right of the two headers on the board's right edge.
## See constraints/PmodSD.xdc for the module's pinout and the timing exceptions.
##
##   Pmod pin  Signal  JC pin  FPGA pin
##   1         ~CS     JC1     K17
##   2         MOSI    JC2     M18
##   3         MISO    JC3     N17
##   4         SCK     JC4     P18
##   9         CD      JC9     P17
##   10        WP      JC10    R18
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports sd_cs]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN P18 IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports sd_cd]
set_property -dict {PACKAGE_PIN R18 IOSTANDARD LVCMOS33} [get_ports sd_wp]
