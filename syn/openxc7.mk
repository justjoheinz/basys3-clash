# Bitstream flow: yosys -> nextpnr-xilinx -> prjxray -> .bit
#
# This makefile runs INSIDE the container built from syn/openxc7.Containerfile,
# which has every tool below on PATH. The host entry point is `make bitstream`;
# you should not need to call this directly.
#
# Its inputs are the Verilog Clash generated, one or more .xdc pin constraint
# files, and the create_clock Clash derived from the Basys3 domain's vPeriod.

TOP_MODULE ?= blinky
PART       ?= xc7a35tcpg236-1
FAMILY     ?= artix7
HDL_DIR    ?= verilog/Blinky.topEntity
OUT_DIR    ?= build/openxc7
# A list: the board's own pins, plus a file per peripheral. `make bitstream`
# fills it in from the design being built.
XDC        ?= constraints/Basys3.xdc

SDC     := $(HDL_DIR)/$(TOP_MODULE).sdc
SOURCES := $(wildcard $(HDL_DIR)/*.v)

# nextpnr's chip database is keyed on the part without its speed grade, so
# xc7a35tcpg236-1 uses xc7a35tcpg236.bin.
DBPART := $(shell echo '$(PART)' | sed -e 's/-[0-9]*$$//')

# CHIPDB and PRJXRAY_DB_DIR come from the image's environment (see
# syn/openxc7.Containerfile), which make imports automatically. These defaults
# only apply when they are unset, e.g. against another openXC7 installation.
CHIPDB         ?= /opt/chipdb
PRJXRAY_DB_DIR ?= $(NEXTPNR_XILINX_DIR)/external/prjxray-db

ifeq ($(wildcard $(CHIPDB)/$(DBPART).bin),)
  $(error No chip database at $(CHIPDB)/$(DBPART).bin -- run this inside the \
    image built by `make openxc7-image`)
endif

SYNTH_OPTS ?=
PNR_ARGS   ?=

JSON   := $(OUT_DIR)/$(TOP_MODULE).json
FASM   := $(OUT_DIR)/$(TOP_MODULE).fasm
FRAMES := $(OUT_DIR)/$(TOP_MODULE).frames
BIT    := $(OUT_DIR)/$(TOP_MODULE).bit

.PHONY: all clean
all: $(BIT)

# fasm2frames writes to stdout, so a failure would otherwise leave an empty
# .frames behind that make considers up to date -- and xc7frames2bit turns an
# empty frame list into a perfectly valid bitstream that configures nothing.
.DELETE_ON_ERROR:

$(OUT_DIR):
	mkdir -p $@

# Synthesis. -flatten because nextpnr-xilinx expects a flat netlist; -abc9
# gives better LUT packing.
$(JSON): $(SOURCES) | $(OUT_DIR)
	yosys -p 'synth_xilinx -flatten -abc9 $(SYNTH_OPTS) -arch xc7 -top $(TOP_MODULE); write_json $@' $(SOURCES)

# Place and route. --xdc is repeatable, so the pin assignments and the
# generated clock constraint go in as separate files rather than being
# concatenated. nextpnr-xilinx reads the set_property -dict form of the pin
# constraints and quietly ignores the commands it does not implement, such as
# set_false_path.
$(FASM): $(JSON) $(XDC) $(SDC)
	nextpnr-xilinx --chipdb $(CHIPDB)/$(DBPART).bin \
	  $(addprefix --xdc ,$(XDC)) --xdc $(SDC) \
	  --json $< --fasm $@ \
	  --write $(OUT_DIR)/$(TOP_MODULE).routed.json \
	  --report $(OUT_DIR)/$(TOP_MODULE).report.json \
	  $(PNR_ARGS)

# FASM is prjxray's textual list of set configuration bits; the last two steps
# turn it into configuration frames and then a Xilinx bitstream.
$(FRAMES): $(FASM)
	fasm2frames --part $(PART) --db-root $(PRJXRAY_DB_DIR)/$(FAMILY) $< > $@

$(BIT): $(FRAMES)
	xc7frames2bit --part_file $(PRJXRAY_DB_DIR)/$(FAMILY)/$(PART)/part.yaml \
	  --part_name $(PART) --frm_file $< --output_file $@
	@echo "Wrote $@"

clean:
	rm -rf $(OUT_DIR)
