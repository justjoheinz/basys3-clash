## The Basys3's four-digit seven-segment display: the shared cathodes, the decimal
## point, and the four digit enables.
##
## Opt-in, for the reason constraints/Basys3.xdc gives: add it to a design's XDC
## list in the Makefile once its top entity has these ports. src/Basys3.hs calls
## the group Display -- a record of cathodes, anodes and decimalPoint -- and names
## the port displayPort, which is a PortProduct that flattens to exactly the three
## names below.
##
## The display is common anode with transistor drivers, so both the cathodes
## (CA..CG = seg[0..6], plus the decimal point) and the digit enables
## (AN0..AN3 = an[0..3]) are active low. Only one digit is lit at a time, which is
## why Peripheral.SevenSegment.display scans: it walks the anodes and puts the
## matching digit's cathode pattern out with it, fast enough that all four look
## lit at once. an[0] is the rightmost digit -- per the reference manual, driving
## AN0 with "1" and AN1 with "7" displays "71".
##
## No timing exception: registered outputs in the design's own clock domain, held
## for a millisecond at a time.
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {seg[0]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33} [get_ports {seg[1]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {seg[2]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports {seg[3]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports {seg[4]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33} [get_ports {seg[5]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {seg[6]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports dp]

set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {an[0]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33} [get_ports {an[1]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports {an[2]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS33} [get_ports {an[3]}]
