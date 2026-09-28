# The switches on the LEDs, the buttons on a counter, and that counter to and
# from the host over UART. Every input the board has except btnC, which is reset.
DESCRIPTION := the switches, the buttons and the host, all at once
TOP_MODULE  := Io
TOP_ENTITY  := io
XDC         := constraints/Basys3.xdc constraints/Basys3-Leds.xdc \
               constraints/Basys3-Display.xdc constraints/Basys3-Switches.xdc \
               constraints/Basys3-Buttons.xdc constraints/Basys3-Uart.xdc
