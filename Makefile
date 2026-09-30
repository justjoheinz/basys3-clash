# Clash designs for the Digilent Basys3.
#
# Everything runs natively on Apple Silicon, place-and-route included: the
# bitstream comes out of yosys + nextpnr-xilinx + prjxray in a native arm64
# container (syn/openxc7.Containerfile). No vendor toolchain, no emulation.
#
# DESIGN picks one design for every target below; `make designs` lists them.
#   make bitstream                the default, examples/design/blinky.mk
#   make bitstream DESIGN=sketch  the smallest one, and the one to copy
#
# PMOD says which header the SD module is plugged into: JA (the default, upper
# left), JB or JC (the right edge). Only the pin constraints change, so this is a
# separate .xdc per header and no HDL difference at all; see constraints/PmodSD.xdc
# for why JXADC is not offered.
STACK       ?= stack
DESIGN      ?= blinky
PMOD        ?= JA
PART        ?= xc7a35tcpg236-1
BOARD       ?= basys3

# One file per design under examples/design/, which is what makes adding a design
# adding files rather than editing this one: a new design is examples/src/Foo.hs
# and examples/design/foo.mk, and every target here then works on it. The list of
# designs is the directory listing, so nothing has to be kept in step by hand --
# including `make designs` and the error below.
DESIGN_DIR  := examples/design
DESIGN_MK   := $(DESIGN_DIR)/$(DESIGN).mk
DESIGNS     := $(sort $(basename $(notdir $(wildcard $(DESIGN_DIR)/*.mk))))

ifeq ($(wildcard $(DESIGN_MK)),)
  $(error Unknown DESIGN '$(DESIGN)' -- expected $(DESIGN_MK). Have: $(DESIGNS))
endif

# What a design file sets: TOP_MODULE, the Haskell module; TOP_ENTITY, the name its
# Synthesize annotation gives the generated HDL; XDC, the pin constraints it needs;
# and optionally OUT_NAME and DESCRIPTION.
#
# XDC is a list -- syn/openxc7.mk passes each file to nextpnr as its own --xdc.
# One file per group of pins, so the list reads as the same information as the
# design's Synthesize annotation, in the same order. Getting it wrong is caught in
# one direction only: a port with no constraint fails late, when nextpnr writes
# FASM, with "port X of type PAD has no IOSTANDARD property", while a constraint
# for a port the design does not have is silently ignored. So a missing file is an
# error and a spare one is not, which is the safe way round but worth knowing.
#
# TOP_ENTITY is spelt out rather than derived from TOP_MODULE by lowercasing it.
# It happens to be the lower-case module name in every design here, but that is a
# convention in the Synthesize annotations, not a rule: the string in `basys3
# "sketch"` is the design's to choose, and deriving it would turn a rename into a
# silent mismatch.
include $(DESIGN_MK)

# Where the output goes. Separate per design, and sd.mk extends it with the header.
OUT_NAME    ?= $(DESIGN)

# `make monitor` opens a serial terminal on the board's USB-UART. screen ships
# with macOS, which is the whole reason it is the default: this target exists to
# answer "is the wire alive" without installing anything first. The recipe execs
# it and nothing else, so this target is `screen PORT BAUD` with the port worked
# out for you. Quit with Ctrl-a k y; Ctrl-a d only detaches, and a detached session
# still holds the port, which breaks the next make flash instead. Anything
# taking `PORT BAUD` positionally drops straight in, e.g.
#   make monitor MONITOR='python3 -m serial.tools.miniterm'   (quit: Ctrl-])
# picocom wants `-b 115200 PORT` and so needs a MONITOR that reorders them.
#
# One USB connector, two FTDI channels, and the host gets a device node for each:
# channel A is the JTAG `make flash` drives, channel B is the UART wired into the
# fabric. Both are real serial devices as far as macOS is concerned, and picking
# the wrong one is the classic way to watch a link that can never say anything.
# The target sorts the nodes and takes the last, because the driver spells the
# channel either A/B or 0/1 depending on its vintage and B sorts after A exactly
# as 1 sorts after 0. SERIAL overrides that outright.
#
# They also contend, though not as simply as it first looked. Observed, not
# reasoned about:
#
#   * a terminal on a `cu.*` node makes `make flash` die with "unable to claim usb
#     device", even on the channel flash is not using. The `cu` device takes
#     TIOCEXCL, which appears to cover the whole FTDI rather than the one channel.
#   * something holding only the `tty.*` twin -- the VS Code Serial Monitor does
#     this -- does not stop a flash. Two flashes ran clean with it attached.
#   * that same `tty.*` opener makes a `cu.*` open fail with EBUSY, so the two
#     terminals contend with each other even where neither blocks flashing.
#
# So: close a `screen` before flashing. Nothing warns you, because from the FTDI's
# point of view nothing is wrong -- hence the note in `make help`.
#
# And do not flash while a `screen` is capturing: openFPGALoader takes the device
# out from under it, and the session dies leaving a log full of NUL bytes that
# reads like a design fault rather than a lost port.
MONITOR ?= screen
BAUD    ?= 115200
SERIAL  ?=

# The toolchain image, built for the host's own architecture.
CONTAINER     ?= podman
OPENXC7_IMAGE ?= openxc7-basys3:local

HDL_DIR     := verilog/$(TOP_MODULE).topEntity
TB_DIR      := verilog/$(TOP_MODULE).testBench
BUILD_DIR   := build
SIM_DIR     := sim
OPENXC7_DIR := $(BUILD_DIR)/openxc7/$(OUT_NAME)
BITSTREAM   := $(OPENXC7_DIR)/$(TOP_ENTITY).bit
VERILOG_TOP := $(HDL_DIR)/$(TOP_ENTITY).v

# What the generated Verilog depends on. Clash follows the imports itself, so
# which modules a given top entity actually needs is a graph make would have to
# duplicate in order to know -- and would get wrong the first time a design gains
# an import. Every source is the honest over-approximation, and a cheap one: the
# Haskell recompile is incremental, so an edit to an unrelated design costs one
# Clash invocation rather than a rebuild. Both packages are here: examples/src holds
# the top entities, src/ the library every one of them draws on. The three package
# descriptions are in the list because their ghc-options reach the generated HDL --
# and they, not the .cabal files hpack derives from them, are what anyone edits.
HS_SOURCES  := $(wildcard examples/src/*.hs src/*.hs src/*/*.hs) \
               package.yaml examples/package.yaml clash-common.yaml

# Waveforms. The command file preselects the interesting signals so the window
# does not open empty. For GTKWave (`brew install --cask gtkwave`) override the
# command-file flag:
#   make waves WAVE_VIEWER=gtkwave WAVE_CMDS=
WAVE_VIEWER ?= surfer
WAVE_CMDS   ?= -c test/surfer-commands.txt
VCD         := $(SIM_DIR)/testBench.vcd

.DEFAULT_GOAL := help
.PHONY: help designs describe build test repl font verilog sim waves lint \
        openxc7-image bitstream flash flash-persist monitor clean distclean

# Unscii 8x8, Viznut's bitmapped font, in the Public Domain. Only the unscii-16-full
# variant is GPL, for carrying GNU Unifont glyphs; this one is not that variant.
UNSCII_URL  ?= http://viznut.fi/unscii/unscii-8.hex
FONT_HS     := src/Screen/Font/Unscii8.hs

help: ## Show this help
	@# MAKEFILE_LIST includes the design file this run included, which would put
	@# its comments in the output. Only this file has ## markers, so grep over
	@# $(MAKEFILE_LIST) stays correct -- but `make designs` is the one to read for
	@# what the designs are.
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

designs: ## List the designs DESIGN can name, with what each one does
	@# Each design's own file is asked what it is, rather than this target holding a
	@# second copy of the list that could go stale.
	@for d in $(DESIGNS); do \
	  what=$$($(MAKE) --no-print-directory -s describe DESIGN=$$d); \
	  if [ "$$d" = "$(DESIGN)" ]; then mark='*'; else mark=' '; fi; \
	  printf "%s \033[36m%-8s\033[0m %s\n" "$$mark" "$$d" "$$what"; \
	done
	@echo "  (* is the current DESIGN; override with DESIGN=<name>)"

describe:
	@echo '$(DESCRIPTION)'

build: ## Compile the Haskell/Clash sources (first run also builds the Clash compiler)
	@# --test --no-run-tests so a plain `make build` type-checks both test suites as
	@# well as the two libraries, without waiting for them to run.
	$(STACK) build --test --no-run-tests

test: ## Haskell-level simulation -- fast, needs no HDL simulator
	@# Both suites: the library's own (spec/) and the designs' (examples/test/).
	@# `stack test basys3` is the first of them alone, which is the one to run after
	@# moving the snapshot pin.
	$(STACK) test

repl: ## Interactive Clash REPL (try: sampleN @System 20 (withClockResetEnable clockGen resetGen enableGen (blinky 2)))
	$(STACK) --silent run clashi -- examples/src/$(TOP_MODULE).hs

font: ## Regenerate the font ROM from upstream unscii-8.hex (needs the network)
	@# $(FONT_HS) is generated and checked in, so this is a one-off: the bytes are in
	@# the repository and a build never reaches for the network. Run it to move to a
	@# new unscii release, and read the diff -- tools/unscii.py says why it is a
	@# generated Haskell module rather than a .hex read at compile time.
	curl -sSfL --max-time 60 '$(UNSCII_URL)' | tools/unscii.py - > $(FONT_HS)
	@echo "$(FONT_HS) regenerated from $(UNSCII_URL)"

verilog: $(VERILOG_TOP) ## Generate Verilog into verilog/

$(VERILOG_TOP): $(HS_SOURCES)
	$(STACK) --silent run clash -- $(TOP_MODULE) --verilog
	@# Deliberately no `touch $@`. Clash keeps a manifest and leaves output whose
	@# inputs hash the same completely untouched, mtime included (checked: editing a
	@# comment and re-running left the .v second-for-second identical). So this
	@# target stays older than the source and Clash re-runs on every make -- one
	@# second, and the price of it is that the bitstream below then sees an
	@# unchanged .v and does not rebuild. Touching it would trade that second for a
	@# full place-and-route every time a comment changed.

sim: verilog ## RTL simulation of the generated test bench with Icarus Verilog
	@# Only the blinky design has a TestBench annotation, so only it generates a
	@# test bench to simulate. The SD controller is exercised in `make test`
	@# instead, against a simulated card in Haskell (spec/FakeSdCard.hs).
	@test -d $(TB_DIR) || { echo "No generated test bench for DESIGN=$(DESIGN)."; exit 1; }
	@mkdir -p $(SIM_DIR)
	@# test/dump.v is a second root module: Clash emits no $dumpvars, so this is
	@# how the run produces a waveform for `make waves`.
	iverilog -g2012 -s testBench -s dump -o $(SIM_DIR)/testBench.vvp \
	  $(TB_DIR)/*.v test/dump.v
	@vvp $(SIM_DIR)/testBench.vvp | tee $(SIM_DIR)/testBench.log
	@# A mismatch makes outputVerifier print and $finish -- vvp still exits 0.
	@if grep -q "expected:" $(SIM_DIR)/testBench.log; then \
	  echo "FAIL: the generated test bench reported a mismatch"; exit 1; \
	else echo "PASS: the generated test bench ran clean"; fi

waves: sim ## Open the simulation waveform in Surfer
	$(WAVE_VIEWER) $(WAVE_CMDS) $(VCD)

lint: verilog ## Lint the generated Verilog with Verilator
	@# No -Wall: it only flags Clash's code-generation style (initialisers in
	@# declarations, helper wires). The default set still catches width
	@# mismatches, undriven and multiply driven signals. test/verilator.vlt
	@# waives one message Clash's vector indexing always trips; see the file.
	verilator --lint-only test/verilator.vlt --top-module $(TOP_ENTITY) $(HDL_DIR)/*.v

openxc7-image: ## Build the toolchain image (one-off, slow -- see the README on podman memory)
	$(CONTAINER) build -t $(OPENXC7_IMAGE) -f syn/openxc7.Containerfile syn

bitstream: $(BITSTREAM) ## Place, route and write the bitstream inside the toolchain image

# The .xdc files are prerequisites as much as the HDL is: a pin change produces a
# different bitstream from identical Verilog, and nothing in a .bit says which
# constraints built it. syn/openxc7.mk is in there for the same reason -- it holds
# the yosys and nextpnr invocations, and $(DESIGN_MK) because it is what names the
# constraints: dropping an .xdc from a design's list has to rebuild it too.
$(BITSTREAM): $(VERILOG_TOP) $(XDC) $(DESIGN_MK) syn/openxc7.mk
	@$(CONTAINER) image exists $(OPENXC7_IMAGE) \
	  || { echo "No $(OPENXC7_IMAGE) image -- run 'make openxc7-image' first."; exit 1; }
	$(CONTAINER) run --rm -v $(CURDIR):/work -w /work $(OPENXC7_IMAGE) \
	  make -f syn/openxc7.mk \
	    TOP_MODULE=$(TOP_ENTITY) PART=$(PART) HDL_DIR=$(HDL_DIR) \
	    OUT_DIR=$(OPENXC7_DIR) XDC='$(XDC)'

# Both flash targets build what they are about to load, rather than checking it
# exists and loading whatever is there. The failure that guards against is silent:
# a bitstream is a plausible-looking file whatever its age, so editing a source
# and flashing used to load the previous design and look like a hardware fault.
# The cost is that `make flash` can take a place-and-route, which is the right
# way round -- `make flash` after no change still only shifts the .bit.
flash: $(BITSTREAM) ## Build if stale, then load into FPGA SRAM (lost on power cycle; close a cu.* terminal first)
	openFPGALoader -b $(BOARD) $(BITSTREAM)

flash-persist: $(BITSTREAM) ## Build if stale, then write to the board's QSPI flash (survives power cycle)
	openFPGALoader -b $(BOARD) -f $(BITSTREAM)

monitor: ## Serial terminal on the board's USB-UART (DESIGN=io; quit Ctrl-a k y; close it before make flash)
	@# cu.* rather than tty.*: the call-out device does not block waiting for
	@# carrier detect, and with no flow-control lines brought out there is no
	@# carrier to wait for.
	@#
	@# Picking the node: the FT2232HQ enumerates one per channel, and only channel
	@# B reaches the FPGA -- channel A is the JTAG that openFPGALoader drives. How
	@# the channel is spelt is the driver's business, not the board's: A/B on some
	@# macOS versions, 0/1 on others (this board gives ...D40 and ...D41). B sorts
	@# after A and 1 after 0, so the last node is the UART under either spelling,
	@# which is why this sorts rather than matching a literal letter. Matching "B"
	@# silently selected channel A on a 0/1 machine -- and an open terminal on
	@# channel A leaves the whole device unclaimable, so make flash fails too with
	@# "unable to claim usb device".
	@port='$(SERIAL)'; \
	if [ -z "$$port" ]; then \
	  nodes=$$(ls /dev/cu.usbserial-* 2>/dev/null); \
	  found=$$(printf '%s\n' "$$nodes" | grep -c .); \
	  port=$$(printf '%s\n' "$$nodes" | tail -1); \
	  case "$$found" in \
	    0) echo "No /dev/cu.usbserial-* found."; \
	       echo "  * is the board plugged into J4 and its power switch on?"; \
	       echo "  * the FT2232HQ enumerates one node per channel, and only the"; \
	       echo "    second of them is wired to the FPGA. Check: ls /dev/cu.*"; \
	       echo "  * override the device with: make monitor SERIAL=/dev/cu.usbserial-XXXX"; \
	       exit 1;; \
	    1) echo "Only one node ($$port): the second channel has not enumerated."; \
	       echo "That is likely the JTAG side, on which nothing will ever arrive.";; \
	    2) ;; \
	    *) echo "$$found usbserial nodes -- more than one FTDI device plugged in?"; \
	       echo "Using the last, $$port. Override with SERIAL= if that is wrong.";; \
	  esac; \
	fi; \
	echo "$(MONITOR) $$port $(BAUD)"; \
	exec $(MONITOR) "$$port" $(BAUD)

clean: ## Remove generated HDL, simulation and bitstream output
	rm -rf verilog $(SIM_DIR) $(BUILD_DIR)

distclean: clean ## Also remove the Haskell build cache (a project rebuild, not a GHC redownload)
	@# One .stack-work per package: object files, the test binary, and at the top
	@# level the package database both are registered into. The compiler and the
	@# snapshot's prebuilt packages live under ~/.stack and are shared between
	@# projects, so this costs a rebuild of the sources here -- not the 474 MB
	@# bindist again.
	rm -rf .stack-work examples/.stack-work
