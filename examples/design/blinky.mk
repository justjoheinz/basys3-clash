# The blinking LEDs. The only design with a TestBench annotation, so the only one
# `make sim` and `make waves` have anything to run.
DESCRIPTION := the blinking LEDs
TOP_MODULE  := Blinky
TOP_ENTITY  := blinky
XDC         := constraints/Basys3.xdc constraints/Basys3-Leds.xdc
