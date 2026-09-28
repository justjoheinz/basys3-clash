## The Basys3's 16 slide switches, SW0 .. SW15, along the bottom edge.
##
## Opt-in, for the reason constraints/Basys3.xdc gives: add it to a design's XDC
## list in the Makefile once its top entity has this port. src/Basys3.hs calls the
## group Switches and names the port switchesPort.
##
## High when the switch is up, low when it is down, with no external pull needed
## either way. sw[0] is the rightmost, directly below led[0].
##
## A slide switch is a mechanical contact like any other and bounces for a few
## hundred microseconds as it wipes, so it is not to be read raw: Peripheral.Button's
## bank, at Basys3.settle cycles, is the conditioning -- one shared counter for all
## sixteen, so the reading moves as a unit once every bit has held still.
## set_false_path says the same thing to the timing analyser, since the first
## flip-flop of a synchroniser has no meaningful setup requirement against a signal
## a finger drives.
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports {sw[3]}]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports {sw[4]}]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports {sw[5]}]
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sw[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sw[7]}]
set_property -dict {PACKAGE_PIN V2  IOSTANDARD LVCMOS33} [get_ports {sw[8]}]
set_property -dict {PACKAGE_PIN T3  IOSTANDARD LVCMOS33} [get_ports {sw[9]}]
set_property -dict {PACKAGE_PIN T2  IOSTANDARD LVCMOS33} [get_ports {sw[10]}]
set_property -dict {PACKAGE_PIN R3  IOSTANDARD LVCMOS33} [get_ports {sw[11]}]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVCMOS33} [get_ports {sw[12]}]
set_property -dict {PACKAGE_PIN U1  IOSTANDARD LVCMOS33} [get_ports {sw[13]}]
set_property -dict {PACKAGE_PIN T1  IOSTANDARD LVCMOS33} [get_ports {sw[14]}]
set_property -dict {PACKAGE_PIN R2  IOSTANDARD LVCMOS33} [get_ports {sw[15]}]

set_false_path -from [get_ports {sw[*]}]
