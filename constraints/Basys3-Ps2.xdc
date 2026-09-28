## The Basys3's USB HID port: a keyboard or mouse in the USB-A connector (J2),
## which reaches the FPGA as a two-wire PS/2 bus on the two pins below.
##
## The USB host is neither the FPGA nor the FT2232HQ. An auxiliary microcontroller
## on the board (a PIC24) does the USB HID host job and re-presents what it hears
## as PS/2, so a design here speaks PS/2 to that microcontroller and never sees USB
## at all. One device at a time, and hubs are not supported.
##
## A keyboard and a mouse are the same two pins and therefore the same file; what
## differs is the protocol above them, which is Haskell rather than constraints.
##
## Nothing in this repository drives these pins. The file is here as verified
## reference material -- the pins are cross-checked against Digilent's
## Basys-3-Master.xdc -- but unlike every other file in constraints/ it has never
## been through place-and-route, because no top entity has these ports for nextpnr
## to match. The names below are this repository's convention; Digilent's master
## file calls them PS2Clk and PS2Data, and the first design to want them settles
## both these and the matching PortName values in src/Basys3.hs.
##
## PS/2 is open collector: both lines idle high through pull-ups and either end
## pulls them low, which is what lets a host inhibit the device by holding the clock
## down. A design that only reads can drive neither and get away with two plain
## inputs, and that is the whole of what a keyboard or a mouse needs to be useful.
##
## Sending is a bigger step than it looks. It needs both pins as true bidirectional
## ports, which is a different port shape and a different Verilog primitive, not a
## direction flag here -- and the far end is the PIC24, not the device, so whether
## the host-to-device direction (keyboard LEDs, mouse resolution and sample rate)
## gets through it at all is a question for Digilent's reference manual. Nothing in
## this repository has tried, so nothing here should be read as saying it works.
##
## ps2_clk is the device's clock, 10 to 16.7 kHz, and it is the device that
## generates it: it has no relationship to this board's 100 MHz oscillator at all.
## Whether it belongs in a clock constraint or a synchroniser is the design's
## choice -- sampling it in the system domain and looking for falling edges is the
## usual answer on a board this size -- and until that choice is made there is
## nothing honest to write here as a timing exception, which is why there is none.
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports ps2_clk]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports ps2_data]

## Digilent's master file sets PULLUP on both, and for an open-collector bus that
## is the right instinct. Commented out for the reason constraints/PmodSD.xdc gives
## for the same property: it is a Vivado property that nextpnr-xilinx silently
## ignores, so leaving it in would suggest a pull-up that the bitstream does not
## actually configure. The board has its own pull-ups on this port.
# set_property PULLUP true [get_ports ps2_clk]
# set_property PULLUP true [get_ports ps2_data]
