## Digilent Basys3 (Artix-7 xc7a35tcpg236-1) -- the two ports every design on this
## board has: the 100 MHz clock, and btnC as the reset. Everything else the board
## carries is a file of its own, listed below.
##
## Pin assignments throughout constraints/ are cross-checked against Digilent's
## Basys-3-Master.xdc: https://github.com/Digilent/digilent-xdc
##
## One file per group of pins, and nothing but this file is a default: a design's
## XDC list in the Makefile names the ones its top entity actually has ports for.
##
##   Basys3-Leds.xdc      led[15:0]
##   Basys3-Display.xdc   seg[6:0], dp, an[3:0]
##   Basys3-Switches.xdc  sw[15:0]
##   Basys3-Buttons.xdc   btnU, btnD, btnL, btnR
##   Basys3-Uart.xdc      uart_rx, uart_tx
##   Basys3-Vga.xdc       vga_red[3:0], vga_green[3:0], vga_blue[3:0], vga_hsync, vga_vsync
##   Basys3-Ps2.xdc       ps2_clk, ps2_data
##   Basys3-Flash.xdc     qspi_dq[3:0], qspi_cs
##   PmodSD.xdc, PmodSD-J{A,B,C}.xdc   the Pmod SD: the module, then the header
##
## Why opt in, rather than constrain the whole board once and forget it: so that a
## design's XDC list says what its pins are, and says it in a form that can be read
## against the design itself. src/Basys3.hs exports one PortName or port group per
## file here, and a design's Synthesize annotation is built out of those, so the two
## lists carry the same names in the same order. XDC is a list in the Makefile and
## syn/openxc7.mk hands nextpnr each file as its own --xdc, so there is nothing here
## to include and nothing to merge.
##
## What the toolchain will and will not catch, measured rather than assumed
## (nextpnr-xilinx; Vivado is stricter about both):
##
##   * A port with no constraint fails, but late and obscurely -- not at placement
##     but at FASM generation, as "ERROR: port dp of type PAD has no IOSTANDARD
##     property". So forgetting a file is caught, and the message names the port
##     rather than the file.
##   * A constraint whose port is not in the netlist is ignored in silence: no
##     error, no warning. So a spare file in a design's list costs nothing and
##     proves nothing, which is why the lists are kept tight by hand.
##
## Three of those files are pins no design here drives yet: the VGA connector, the
## PS/2 port and the configuration flash. Nothing has been through place-and-route
## with them, so the port names in them are a proposal that the first design to
## want them settles -- unlike every other file here, which is exercised by
## `make bitstream`.

## 100 MHz system clock. Only the pin is assigned here: the period comes from
## the Basys3 domain's vPeriod in src/Basys3.hs, which Clash emits beside each
## design's Verilog as a .sdc that syn/openxc7.mk feeds to nextpnr as a further
## --xdc. Declaring it in one place keeps the Haskell model and the timing
## constraint in step.
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]

## Centre push button (btnC) used as an active-high reset. It is the one button
## not in constraints/Basys3-Buttons.xdc, and the reason is that it is not an
## input to the design at all: the Basys3 domain declares an active-high
## asynchronous reset, and Basys3.onBoard wires this pin to it.
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports rst]

## btnC feeds the reset from a pin, so it is not clock synchronous and belongs
## out of timing analysis. It no longer reaches the design's flip-flops directly:
## Basys3.onBoard passes it through Clash's resetGlitchFilter, which debounces it
## over Settle cycles (see src/Basys3.hs). This constraint now covers that
## filter's input register, which is exactly where a false path belongs -- the
## register that first samples an asynchronous input.
set_false_path -from [get_ports rst]
