## The four outer push buttons of the Basys3's five-way cross.
##
## Opt-in, for the reason constraints/Basys3.xdc gives: add it to a design's XDC
## list in the Makefile once its top entity has these ports. src/Basys3.hs names
## them btnUPort, btnDPort, btnLPort and btnRPort, and buttonPorts is the four in
## the order below -- up, down, left, right -- which is the order a design that
## takes all of them should take them.
##
## btnC, the centre one, is deliberately absent: it is the reset, and
## constraints/Basys3.xdc assigns U18 to the rst port already. All five read high
## when pressed and low otherwise, with no external pull needed either way.
##
## These bounce for a few hundred microseconds, so anything counting edges sees one
## press as a handful: Peripheral.Button's contact, at Basys3.settle cycles, is the
## conditioning, and it is what makes one press one step. set_false_path says the
## same thing to the timing analyser, since the first flip-flop of a synchroniser
## has no meaningful setup requirement against a signal a finger drives.
set_property -dict {PACKAGE_PIN T18 IOSTANDARD LVCMOS33} [get_ports btnU]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports btnD]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports btnL]
set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} [get_ports btnR]

set_false_path -from [get_ports btnU]
set_false_path -from [get_ports btnD]
set_false_path -from [get_ports btnL]
set_false_path -from [get_ports btnR]
