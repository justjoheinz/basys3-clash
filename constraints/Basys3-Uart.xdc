## The Basys3's USB-UART bridge: the two FPGA pins wired to channel B of the
## FT2232HQ. Pin assignments cross-checked against Digilent's Basys-3-Master.xdc:
## https://github.com/Digilent/digilent-xdc
##
## Not part of the default constraint set, for the reason
## constraints/Basys3-Inputs.xdc gives: a .xdc that names ports the netlist does
## not have is at best noise and at worst an error. Add it to a design's XDC list
## in the Makefile only once its top entity has these ports, as DESIGN=io does:
##
##   XDC ?= constraints/Basys3.xdc constraints/Basys3-Inputs.xdc \
##          constraints/Basys3-Uart.xdc
##
## The FT2232HQ is a two-channel part doing two different jobs on one cable and
## one connector (J4): channel A is the USB-JTAG openFPGALoader talks to, and
## channel B is a USB-UART bridge wired into the fabric. They are independent
## interfaces, which is why `make flash` and `make monitor` do not fight over the
## board.
##
## Direction below is from the FPGA's point of view. The schematic net names are
## from the bridge's, which is why the net called UART_TXD_IN is our input:
##
##   our port   pin   schematic net   Digilent's port   direction
##   uart_rx    B18   UART_TXD_IN     RsRx              input   (host -> FPGA)
##   uart_tx    A18   UART_RXD_OUT    RsTx              output  (FPGA -> host)
##
## RTS and CTS are not brought out to the FPGA at all, so neither end can ask the
## other to wait; see the README on what that costs.
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports uart_tx]

## uart_rx is driven by the bridge's own oscillator and has no phase relationship
## to this clock at all, so it has no meaningful setup requirement against it --
## the same situation as a button, and the same answer: Protocol.UART synchronises
## it with two flip-flops and then samples the middle of each bit. uart_tx is a
## registered output whose only consumer is on this board, a centimetre away.
set_false_path -from [get_ports uart_rx]
set_false_path -to [get_ports uart_tx]
