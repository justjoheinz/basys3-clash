## The Basys3's quad-SPI configuration flash (Spansion S25FL032P, 32 Mbit): the
## four data lines and the chip select, as seen by user logic after configuration.
##
## Nothing in this repository drives these pins, and this is the file in
## constraints/ to be most careful with. It is here as verified reference material
## -- the pins are cross-checked against Digilent's Basys-3-Master.xdc -- but it
## has never been through place-and-route, because no top entity has these ports.
## The names below are this repository's convention; Digilent's master file calls
## them QspiDB and QspiCSn, the n for active low, which the chip select is.
##
## Three things make this different from every other group on the board:
##
##   * There is no clock pin to constrain, and its absence from Digilent's master
##     file is not an oversight. The flash's SCK is the FPGA's dedicated CCLK,
##     which is not a user-assignable I/O at all: a design reaches it through the
##     STARTUPE2 primitive's USRCCLKO input. So a quad-SPI master here cannot just
##     be Protocol.SPI with a wider data path and these five pins.
##   * These are the nets the FPGA configures itself from. `make flash-persist`
##     writes a bitstream to this flash and the board loads it on power-up, so a
##     design that drives these pins is sharing them with the configuration
##     engine, and getting that wrong is how a board stops booting. The engine
##     releases them after configuration finishes, which is what makes user access
##     possible at all -- but only after.
##   * The 32 Mbit part is mostly empty after a bitstream for this device, which is
##     the attraction: it is the only non-volatile storage on the board.
##
## No timing exceptions, for the reason the other two undriven files give: what
## they should be depends on how the design clocks the bus, and nothing has.

## Data lines DQ0 .. DQ3. In plain SPI mode DQ0 is MOSI and DQ1 is MISO.
set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {qspi_dq[0]}]
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports {qspi_dq[1]}]
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports {qspi_dq[2]}]
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports {qspi_dq[3]}]

## Chip select, active low.
set_property -dict {PACKAGE_PIN K19 IOSTANDARD LVCMOS33} [get_ports qspi_cs]
