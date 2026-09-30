## The Basys3's VGA connector: four bits per colour channel, plus the two syncs.
##
## The library drives these pins -- Basys3.screen and Basys3.vgaPins, over
## Protocol.VGA and Screen -- but no design here does yet, so unlike every other
## file in constraints/ this one has never been through place-and-route: no top
## entity has these ports for nextpnr to match. The pins themselves are
## cross-checked against Digilent's Basys-3-Master.xdc. Two things worth knowing
## before using it:
##
##   * The port names below are this repository's convention (lower case, one word
##     per pin group) rather than Digilent's, whose master file calls them vgaRed,
##     vgaGreen, vgaBlue, Hsync and Vsync. They are settled: Basys3.vgaPort is the
##     matching PortName list, in this file's order, and spec/Spec.hs pins the
##     field order and the 14-bit width of the Vga record it comes from. What is
##     still unverified is these fourteen names against those five -- a mismatch
##     shows up only in nextpnr's FASM step, as "port X of type PAD has no
##     IOSTANDARD property", and the first design to have VGA ports is what
##     provokes it.
##   * There are no timing exceptions here, and that is now an answer rather than
##     a deferral. VGA wants a pixel clock -- 25.175 MHz for 640x480 at 60 Hz --
##     and the library does not make one: Basys3.pixel is a 1-in-4 enable in the
##     ordinary 100 MHz Basys3 domain, so 25.000 MHz is a quarter of the clock
##     that is already constrained and there is no second domain to relate this
##     one to. That is deliberate. A create_clock plus a set_clock_groups is
##     exactly the shape of constraint nextpnr-xilinx accepts and silently ignores
##     (see the README), so a real pixel-clock domain here would look safe and be
##     unchecked. These are registered outputs of the 100 MHz domain, all fourteen
##     of them from one register, and the existing clock constraint covers them.
##
## Electrically each channel is a 4-bit resistor DAC: 16 levels per colour, 4096
## colours. The monitor terminates each line into 75 ohm, which the resistor
## network is sized for, so a channel driven high is not a short -- but it is also
## not a digital output whose level means anything on its own.

## Red, bit 0 the least significant.
set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} [get_ports {vga_red[0]}]
set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS33} [get_ports {vga_red[1]}]
set_property -dict {PACKAGE_PIN J19 IOSTANDARD LVCMOS33} [get_ports {vga_red[2]}]
set_property -dict {PACKAGE_PIN N19 IOSTANDARD LVCMOS33} [get_ports {vga_red[3]}]

## Green.
set_property -dict {PACKAGE_PIN J17 IOSTANDARD LVCMOS33} [get_ports {vga_green[0]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {vga_green[1]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {vga_green[2]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {vga_green[3]}]

## Blue.
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports {vga_blue[0]}]
set_property -dict {PACKAGE_PIN L18 IOSTANDARD LVCMOS33} [get_ports {vga_blue[1]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports {vga_blue[2]}]
set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} [get_ports {vga_blue[3]}]

## Horizontal and vertical sync. Both are active low for 640x480 at 60 Hz, which
## is a property of the mode rather than of the board.
set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} [get_ports vga_hsync]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports vga_vsync]
