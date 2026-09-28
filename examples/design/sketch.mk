# The switches on the LEDs, their value in hex on the display and in decimal on
# the host. The smallest complete design, and the one to copy.
DESCRIPTION := the switches, in hex on the display and decimal on the host
TOP_MODULE  := Sketch
TOP_ENTITY  := sketch
XDC         := constraints/Basys3.xdc constraints/Basys3-Leds.xdc \
               constraints/Basys3-Display.xdc constraints/Basys3-Switches.xdc \
               constraints/Basys3-Uart.xdc
