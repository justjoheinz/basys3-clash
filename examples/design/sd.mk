# Reading block zero of an SD card on a Pmod SD.
#
# The only design whose pins depend on something outside the HDL: PMOD says which
# header the module is plugged into, and only the constraints differ. OUT_NAME
# carries it, because nothing in a .bit says which header it was built for and a
# bitstream for the wrong one looks exactly like a card that will not answer.
DESCRIPTION := block zero of an SD card on a Pmod SD (PMOD=JA, JB or JC)
TOP_MODULE  := Sd
TOP_ENTITY  := sd
OUT_NAME    := sd-$(PMOD)

PMOD_XDC    := constraints/PmodSD-$(PMOD).xdc
ifeq ($(wildcard $(PMOD_XDC)),)
  $(error No constraints for PMOD '$(PMOD)' -- expected $(PMOD_XDC))
endif

XDC         := constraints/Basys3.xdc constraints/Basys3-Leds.xdc \
               constraints/Basys3-Display.xdc constraints/PmodSD.xdc $(PMOD_XDC)
