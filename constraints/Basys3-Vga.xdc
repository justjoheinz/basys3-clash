## The Basys3's VGA connector: four bits per colour channel, plus the two syncs.
##
## Nothing in this repository drives these pins. The file is here as verified
## reference material -- the pins are cross-checked against Digilent's
## Basys-3-Master.xdc -- but unlike every other file in constraints/ it has never
## been through place-and-route, because no top entity has these ports for nextpnr
## to match. Two consequences worth knowing before using it:
##
##   * The port names below are this repository's convention (lower case, one word
##     per pin group) rather than Digilent's, whose master file calls them vgaRed,
##     vgaGreen, vgaBlue, Hsync and Vsync. Nothing has settled them; the first
##     design to want VGA settles them, together with the matching PortName values
##     in src/Basys3.hs.
##   * There are no timing exceptions here, and that is not an omission: what they
##     should be depends on how the design drives the connector. VGA wants a pixel
##     clock -- 25.175 MHz for 640x480 at 60 Hz, which the Basys3's 100 MHz divides
##     to 25 MHz, close enough for every monitor in practice -- so these are
##     registered outputs of whatever domain that clock belongs to, and the
##     constraint that matters is the one relating that domain to this one.
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
