## The Basys3's remaining inputs: the 16 slide switches and the four outer push
## buttons. Pin assignments cross-checked against Digilent's Basys-3-Master.xdc:
## https://github.com/Digilent/digilent-xdc
##
## Not part of the default constraint set, because a .xdc that names ports the
## netlist does not have is at best noise and at worst an error. Add it to a
## design's XDC list in the Makefile only once its top entity has these ports,
## as DESIGN=io does:
##
##   XDC ?= constraints/Basys3.xdc constraints/Basys3-Inputs.xdc
##
## btnC is not here: it is the reset, and constraints/Basys3.xdc assigns U18 to
## the rst port already. All five buttons read high when pressed and low
## otherwise, with no external pull needed either way.
##
## Every one of these is a mechanical contact, asynchronous to the clock and
## bouncing for a few hundred microseconds. Peripheral.Button's contact and bank,
## at Basys3.settle cycles, are the conditioning; set_false_path below says the
## same thing to the timing analyser, since the first flip-flop of a synchroniser
## has no meaningful setup requirement against a signal a finger drives.

## Slide switches SW0 .. SW15, sw[0] rightmost.
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

## The four outer push buttons of the five-way cross.
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports btnU]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports btnD]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports btnL]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports btnR]

set_false_path -from [get_ports {sw[*]}]
set_false_path -from [get_ports btnU]
set_false_path -from [get_ports btnD]
set_false_path -from [get_ports btnL]
set_false_path -from [get_ports btnR]
