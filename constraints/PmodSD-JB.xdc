## Pmod SD on header JB -- the left of the two headers on the board's right edge.
## See constraints/PmodSD.xdc for the module's pinout and the timing exceptions.
##
##   Pmod pin  Signal  JB pin  FPGA pin
##   1         ~CS     JB1     A14
##   2         MOSI    JB2     A16
##   3         MISO    JB3     B15
##   4         SCK     JB4     B16
##   9         CD      JB9     C15
##   10        WP      JB10    C16
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports sd_cs]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports sd_cd]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports sd_wp]
