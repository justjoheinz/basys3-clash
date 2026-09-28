## Digilent Pmod SD (microSD card slot) -- the parts that do not depend on which
## header it is plugged into. The pins themselves come from a second file,
## constraints/PmodSD-<header>.xdc, chosen by `make bitstream DESIGN=sd PMOD=JB`.
##
## Pmod SD pinout (Rev B), header pin -> signal:
##   1 ~CS   2 MOSI  3 MISO  4 SCK   5 GND  6 VCC
##   7 DAT1  8 DAT2  9 CD   10 WP   11 GND 12 VCC
## DAT1 and DAT2 are only used in SD mode, not SPI mode, so they are left
## unconstrained: the top-level design never mentions them. CD and WP are the
## socket's mechanical switches; they are shown on LEDs 8 and 9 and nothing is
## gated on them, so their polarity -- a property of the socket, not of us --
## cannot break a card read.
##
## Three of the board's four headers are offered: JA (upper left), JB and JC (the
## right edge). Not JXADC, the lower-left one: it is wired as two coupled
## differential pairs sharing the XADC's anti-alias filter footprints, and
## Digilent's reference manual warns that this "might limit the data speeds when
## used for digital signals". Should it ever be needed anyway, its pins are
##   JXADC1..4 = J3 L3 M2 N2, JXADC7..10 = K3 M3 M1 N1
## in the same order as the files next to this one.

## Nothing here is clock synchronous in the sense timing analysis cares about:
## SCK is a divided-down output, and MISO is sampled at 400 kHz, some 125 cycles
## after the edge that caused the card to drive it.
set_false_path -to [get_ports sd_cs]
set_false_path -to [get_ports sd_sck]
set_false_path -to [get_ports sd_mosi]
set_false_path -from [get_ports sd_miso]
set_false_path -from [get_ports sd_cd]
set_false_path -from [get_ports sd_wp]

## If MISO ever floats -- no card, or a card that has released the line -- an
## internal pull-up makes it read as 0xFF, which is exactly what the controller
## treats as "the card has not answered yet". Commented out because it is a
## Vivado property that nextpnr-xilinx silently ignores; the Pmod SD carries its
## own pull-ups, so this is belt and braces rather than a requirement.
# set_property PULLUP true [get_ports sd_miso]
# set_property PULLUP true [get_ports sd_cd]
# set_property PULLUP true [get_ports sd_wp]
