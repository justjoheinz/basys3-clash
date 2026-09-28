# blinky — Clash on the Digilent Basys3

All 16 of the Basys3's LEDs blinking together, one second on and one second off,
with the four-digit display counting the blinks — 0001, 0002, … 9999, 0000 —
written in Haskell with [Clash](https://clash-lang.org) and built on Apple
Silicon.

The board is a Digilent Basys3: AMD Artix-7 `xc7a35tcpg236-1`, 100 MHz clock on
pin W5, 16 LEDs, a four-digit seven-segment display, and an FT2232HQ that is both
the USB-JTAG programmer and a USB-serial bridge.

Two more designs live here, and every target takes `DESIGN=` to pick one:

- `DESIGN=sd` — `SdDemo` brings up an SD card over SPI on a Digilent Pmod SD and
  reads block zero, showing the result on the same LEDs and display. See
  [Reading an SD card](#reading-an-sd-card).
- `DESIGN=io` — `IoDemo` puts the slide switches on the LEDs and the four outer
  buttons on a counter, and sends that counter to the host over the serial bridge
  — or takes it from there. See
  [The switch-and-button demo](#the-switch-and-button-demo) and
  [Talking to the host](#talking-to-the-host).

## The pipeline

Everything here runs natively on arm64 macOS, including place-and-route: the
open-source toolchain (yosys, nextpnr-xilinx, prjxray) builds as an arm64
container image, with no Rosetta or qemu anywhere. No vendor toolchain is
involved at any stage.

```
Blinky.hs ──stack test──────────────► Haskell-level simulation   (native)
    │
    └────clash --verilog────────────► verilog/                    (native)
              │
              ├──iverilog / vvp ────► RTL test bench              (native)
              ├──surfer ────────────► waveforms                   (native)
              ├──verilator ─────────► lint                        (native)
              │
              └──yosys ─► nextpnr-xilinx ─► prjxray   (native, in podman)
                                         └─► build/openxc7/blinky/blinky.bit
                                                   │
                              openFPGALoader ◄─────┴──► board     (native)
```

## Prerequisites

Haskell side — Stack, and nothing else. Stack installs and owns the compiler
itself, so there is no GHC version to keep in step by hand:

```bash
ghcup install stack        # or: brew install haskell-stack
```

`stack.yaml` pins the snapshot `nightly-2026-09-24`, which carries Clash 1.10.2 on
GHC 9.12.4 and so needs no `extra-deps` at all. Why a dated nightly and not an LTS
— and why nothing in it corresponds to cabal's `write-ghc-environment-files` — is
in that file's own comments.

For editor support, `haskell-language-server` needs to be new enough to have a
binary for that compiler: 2.14.0.0 does, 2.13.0.0 does not.

Native tooling:

```bash
brew install icarus-verilog verilator openfpgaloader surfer
brew install podman        # runs the synthesis toolchain; see `make bitstream`
```

Verilog is the only HDL this project generates. Clash can also emit VHDL and
SystemVerilog, but Verilog has the better native tooling on macOS: Verilator
(lint, and the fastest simulator) reads no VHDL at all, Homebrew's `ghdl` cask is
disabled for failing the Gatekeeper check, and Yosys — which does the synthesis
here — is Verilog-first. The generated Verilog is also easier to read — one
self-contained test bench file, and no escaped identifiers like
`\Blinky.testBench_clk\`.

The first `stack build` also downloads GHC and compiles `clash-ghc`, which takes a
while (it's a compiler). Subsequent builds are incremental.

## Usage

```bash
make            # list targets
make test       # Haskell-level simulation, no HDL simulator involved
make repl       # interactive Clash REPL
make verilog    # generate Verilog into verilog/Blinky.topEntity/
make sim        # run the generated HDL test bench in Icarus Verilog
make waves      # open the waveform in Surfer
make lint       # Verilator lint over the generated Verilog

make openxc7-image  # one-off: build the synthesis toolchain image
make bitstream      # yosys + nextpnr-xilinx + prjxray -> build/openxc7/blinky.bit
make flash          # load it onto the board

make bitstream DESIGN=sd && make flash DESIGN=sd   # the SD card demo instead
make bitstream DESIGN=io && make flash DESIGN=io   # the switches and buttons

make monitor    # serial terminal on the board, for DESIGN=io
                # close it again before the next make flash: one USB device
```

`DESIGN` (`blinky`, the default, or `sd`, or `io`) picks the top-level module, the
entity name the bitstream is called after, and which pin constraint files are used.
It applies to every target except `make test`, which always runs every check, and
`make monitor`, which only opens a terminal.
`make sim` and `make waves` only work for `blinky`: it is the design with a
`TestBench` annotation.

### Looking at waveforms

The simulator itself is headless; the UI is a waveform viewer.
[Surfer](https://surfer-project.org) is a native arm64 Homebrew formula:

```bash
make waves      # Icarus -> sim/testBench.vcd -> Surfer
```

`make sim` always writes a VCD, because `test/dump.v` is compiled in as a second
root module alongside the generated test bench (Clash emits no `$dumpvars`, and
the generated file should not be edited).

`test/surfer-commands.txt` preselects `clk`, `rst`, the blink prescaler (`tick`,
`count`), the blink phase `lit`, the four BCD `digits` and the display scan
(`tick_0`, `sel`), so the window opens on something readable rather than empty.

For GTKWave, whose flags differ, override them:

```bash
make waves WAVE_VIEWER=gtkwave WAVE_CMDS=
```

### Simulation, two ways (plus hardware)

1. **Haskell level (`make test`, `make repl`)** — the fastest loop, and the
   reason to use Clash at all. `Signal dom a` is an infinite stream, so you
   simulate by sampling it:

   ```haskell
   sampleN @System 20 (withClockResetEnable clockGen resetGen enableGen (blinky 2 100))
   ```

2. **Generated HDL (`make sim`)** — `testBench` in `examples/src/Blinky.hs` is compiled
   to a real Verilog test bench with assertions. This is what catches divergence
   between the Haskell semantics and the emitted RTL.

   Note that a mismatch makes Clash's `outputVerifier` print and call
   `$finish`, and `vvp` still exits 0, so `make sim` greps the log and reports
   PASS/FAIL itself. That was checked against a deliberately wrong expected
   value.

3. **The actual FPGA** — `make bitstream && make flash`.

### Getting a bitstream

`make bitstream` runs the open-source Xilinx flow, which needs no vendor
toolchain and no x86 machine:

```bash
make openxc7-image    # one-off: build the toolchain image (~30 min)
make bitstream        # yosys -> nextpnr-xilinx -> prjxray -> .bit
make flash
```

The stages, all inside the container (`syn/openxc7.mk`):

| Tool | Step |
| --- | --- |
| `yosys -p 'synth_xilinx'` | Verilog → a technology-mapped JSON netlist |
| `nextpnr-xilinx` | place and route against a chip database → FASM |
| `fasm2frames` | FASM (textual list of set config bits) → config frames |
| `xc7frames2bit` | frames → `blinky.bit` |

Its inputs are the Clash-generated Verilog, the design's `.xdc` files, and the
`create_clock` Clash derives from the `Basys3` domain. nextpnr's XDC reader
accepts `set_property -dict` with `PACKAGE_PIN`/`IOSTANDARD` and quietly ignores
the commands it does not implement, such as `set_false_path`. `--xdc` is
repeatable, so the board's pins, a peripheral's pins and the generated `.sdc` go
in as separate files rather than being concatenated — which is why adding the
Pmod SD meant adding a file, not editing one.

It is genuinely native. [openXC7](https://github.com/openXC7) packages the
toolchain as a Nix flake that supports `aarch64-linux`, so
`syn/openxc7.Containerfile` builds an arm64 image on Apple Silicon and Nix stays
inside the container — nothing is installed on the Mac, and `podman rmi
openxc7-basys3:local` removes every trace.

Three things about that image are worth knowing, because they are all worked
around in the Containerfile rather than fixed upstream:

- **It does not use `nix develop`.** The flake's dev shell also builds
  `fpga-assembler`, whose Bazel dependency tarball currently fails its
  fixed-output hash check on aarch64, which fails the whole shell. Installing
  only the needed packages avoids it.
- **The chip database for this part is generated locally.** The prebuilt
  `nextpnr-xilinx-chipdb.artix7` package ships 17 Artix-7 parts but omits every
  `xc7a35t` variant, although prjxray-db describes all four speed grades. The
  image runs `bbaexport.py` + `bbasm` for `xc7a35tcpg236` itself, the same way
  upstream's chipdb derivation does.
- **The Python environment is spelled out.** `fasm/parser/__init__.py` imports
  `pyximport` unconditionally, but nixpkgs' `python3.12-fasm` propagates only
  textX, and prjxray additionally wants `yaml`, `numpy` and `intervaltree`.

Compiling `nextpnr-xilinx` needs roughly 2 GB of RAM per translation unit, and
the default podman machine has about 4 GB, which OOM-kills `cc1plus`. Give the
VM more before building the image:

```bash
podman machine stop && podman machine set --memory 12288 && podman machine start
```

What this toolchain does not cover: MMCM/PLL, BRAM and DSP support are not worth
relying on yet, timing analysis is coarser than the vendor's, and there is no
hard IP. For counters, a decoder and a display scan none of that matters; a design that
needs a clock generator or block RAM would have to check what nextpnr-xilinx
supports first.

This flow has been run end to end here, onto real hardware: `make flash` loads
the bitstream over USB-JTAG, the FPGA asserts DONE, and the LEDs do what the
simulation says they should. It produces `blinky.bit` (2 192 130 bytes, the fixed
frame count for this part), nextpnr reports 201.01 MHz against the
100 MHz constraint, and all 30 constrained pins resolve to IOB tiles that
appear in the FASM with `LVCMOS33` drive and slew settings — which is what
confirms the `PACKAGE_PIN` constraints were actually applied rather than silently
ignored. Repeated runs produce byte-identical FASM and frames, so place-and-route
is deterministic; two `.bit` files still differ in their first few hundred bytes,
because `xc7frames2bit` writes the input path and the build date into the header.

### Flashing

```bash
make flash          # into SRAM, gone on power cycle
make flash-persist  # into QSPI flash, survives power cycle
```

Both build what they are about to load. `make flash` on its own is enough: the
targets are real files with real prerequisites, so editing a module and flashing
re-runs Clash, place-and-route and the bitstream write, while flashing twice in a
row only shifts the `.bit`. Bitstreams depend on their `.xdc` files too, because a
pin change produces different hardware from identical Verilog.

This is worth the wait it sometimes costs, because the failure it removes is
silent: a bitstream is a plausible-looking file whatever its age. `make flash` used
to check the file merely *existed*, so editing a source and flashing loaded the
previous design — and a design that behaves like the one before your change looks
exactly like a hardware fault. That happened here, and cost a real debugging
session before the timestamps gave it away.

Note that neither target runs `make test`. Simulation is fast and flashing is not,
so run the tests yourself first; they will not stop you flashing a design that
fails them.

Board settings, per Digilent's reference manual:

- **SW16**, the power switch (top left), on — LD20, the power-good LED, confirms it.
- **JP2**, next to the power switch, on `USB` when the board is powered from the
  programming cable. `EXT` expects 4.5–5.5 V at ≥ 1 A on header J6.
- The cable goes into the micro-USB port **J4**, silkscreened `PROG`. The USB-A
  port J2 is the HID host, not a programming port.
- **JP1**, the programming mode jumper, on `JTAG` — though JTAG downloads work
  "regardless of what the mode jumper (JP1) is set to". JP1 only chooses what the
  FPGA loads on power-up or after pressing PROG: `JTAG` waits for a download,
  `QSPI` loads the onboard flash, `USB` loads a single `.bit` from the root of a
  FAT32 stick in J2. Move it to `QSPI` after `make flash-persist` if you want the
  design back by itself after a power cycle; the write itself goes over JTAG
  either way.

DONE lights when configuration succeeds; the PROG button clears it.

`openFPGALoader -b basys3` talks to the board's FT2232HQ directly via libusb;
Digilent's Adept runtime (Windows/Linux only) is not needed. If the board isn't
found, check `openFPGALoader --scan-usb` — macOS's built-in FTDI driver can
occasionally claim the interface, in which case unplugging and replugging after
starting the command is the usual fix.

Expected behaviour: all 16 LEDs on for one second, off for one second, and the
display incrementing by one on every cycle — 0001, 0002, … 9999, then back to
0000. Pressing the centre button (btnC) holds the LEDs dark and the display at
0000, and restarts on release.

## Reading an SD card

`make bitstream DESIGN=sd && make flash DESIGN=sd` builds the SD design: it
initialises an SD card over SPI on a [Pmod SD](https://digilent.com/reference/pmod/pmodsd/start)
and reads block zero.

### Wiring

The module goes on **JA** by default, the upper of the two Pmod headers on the
board's left edge — but any of three headers works, chosen with `PMOD`:

```bash
make bitstream DESIGN=sd PMOD=JB && make flash DESIGN=sd PMOD=JB
```

| Pmod SD pin | Signal | JA | JB | JC |
| --- | --- | --- | --- | --- |
| 1 | `~CS` | J1 | A14 | K17 |
| 2 | `MOSI` | L2 | A16 | M18 |
| 3 | `MISO` | J2 | B15 | N17 |
| 4 | `SCK` | G2 | B16 | P18 |
| 9 | `CD` (card detect) | H2 | C15 | P17 |
| 10 | `WP` (write protect) | G3 | C16 | R18 |

Pins 7 and 8 (`DAT1`, `DAT2`) are only used in SD mode, not SPI mode, and are
left unconnected.

Nothing in the HDL knows about this: the port names in the generated Verilog are
the same either way, so a header is one `.xdc` per header
(`constraints/PmodSD-JA.xdc` and friends) plus the shared
`constraints/PmodSD.xdc`, and `PMOD` just picks which pair goes to nextpnr.
Adding a header means adding a file — the Makefile checks that the file exists
rather than knowing the names.

Each combination gets its own output directory (`build/openxc7/sd-JB/` and so on),
because a bitstream records nothing about the pins it was built for: flashing a
JA build with the module in JB looks exactly like a card that will not answer,
which is a confusing half hour.

The fourth header, JXADC (lower left), is deliberately not offered: it is wired as
two coupled differential pairs sharing the XADC's anti-alias filter footprints,
and Digilent's reference manual warns that this "might limit the data speeds when
used for digital signals". Its pins are recorded in `constraints/PmodSD.xdc` for
anyone who wants to try anyway.

### Reading the result

The display shows the **last two bytes of block zero** as four hex digits. A
formatted card has the `0x55AA` boot signature there, so a successful read ends
with `55AA` on the display. If an attempt fails, the display switches to a
diagnostic instead: `F`, the stage that failed, and the status byte (R1) the card
answered with — so `F1FF` means CMD0 never got an answer, which is what an empty
socket looks like.

The LEDs say the same thing continuously, most significant first:

| LEDs | Meaning |
| --- | --- |
| 15 | the card came up and the block was read |
| 14 | an attempt has failed |
| 13–10 | unused |
| 9, 8 | the write-protect and card-detect pins, as they read |
| 7–4 | the stage that gave up |
| 3–0 | the current stage |

Stage codes are `Stage`'s constructor order: 0 power-on clocking, 1 CMD0,
2 CMD8, 3 CMD55, 4 ACMD41, 5 CMD58, 6 CMD17, 7 ready, 8 failed. While it is
retrying, LEDs 3–0 flicker through each attempt's stages, so read them as a blur
rather than a number.

Failure is not final: giving up starts the sequence over, so inserting a card
turns `F1FF` into the card's data within a few milliseconds, with no button press.
Success *is* final — once the block has been read the bus is left alone, so btnC,
which resets the domain, is how to re-read after swapping cards. The bus runs at
400 kHz, the fastest a card may be clocked before it is initialised, so the
512-byte block itself takes about 11 ms.

Because `Failed` is a passing state, `SdDemo` latches it and the diagnostic word;
anything else built on `Pmod.SdCard` has to do the same to report a failure.

This has been run on the board, not just in simulation: with the Pmod on JA and
an empty socket the display reads `F1FF`, and a formatted microSD card brings up
`55AA`. nextpnr reports 136.44 MHz against the 100 MHz constraint, and the six
Pmod pins were cross-checked against prjxray's `package_pins.csv` — `sd_cs` at
`IOB_X1Y93` is J1, and so on — which is what confirms the second `.xdc` was
applied rather than silently ignored.

### How it is put together

| Module | Role |
| --- | --- |
| `Protocol.SPI` | A byte-at-a-time SPI mode-0 master. Knows nothing about SD — not even that a chip select exists. |
| `Pmod.SdCard` | The protocol: CMD0, CMD8, CMD55/ACMD41, CMD58, CMD17, and the timeouts. |
| `Pmod.FakeSdCard` | A pretend card, in the test suite: a real SPI slave that answers like one. |
| `SdDemo` | The board wrapper — pins, LEDs, display. |

`Pmod.FakeSdCard` is why this could be written without a board in the loop. `make
test` runs the controller against it bit by bit: the full initialisation
sequence, the ACMD41 retry loop, the start-of-block token and all 512 bytes,
checked against what the pretend card holds. The SPI master is separately checked
with MISO tied to MOSI, which only echoes correctly if it shifts out and samples
in on the edges it claims to.

The SCK period is a parameter, not a constant, which is what makes that possible:
the board instantiates `sdCard 124` (400 kHz at 100 MHz) and the tests
instantiate `sdCard 1` (an edge every two cycles), so a block read simulates in
about 30 000 cycles instead of 3 million.

### Why it is hand-written

There is no Clash library for any of this. What exists in the ecosystem:

- **`clash-cores`** has `Clash.Cores.Spi` (`spiMaster`, `spiSlave`, all four
  modes) and a UART, CRC and Xilinx-primitive wrappers — but it lives in its own
  repository and is not on Hackage, so it has to be vendored from git. Its SPI
  master is bit-oriented and generic; the SD sequencing above it would still be
  yours to write.
- **I²C** is not in `clash-cores` at all. The OpenCores I²C master has been
  ported to Clash, but as `examples/i2c` inside the `clash-compiler` repository,
  complete with a simulated slave to test against.
- **Pmod support** is Digilent's own, and it is a software stack: their
  `PmodSD_v1_0` IP is an AXI Quad SPI block plus FatFs drivers in C++ for a
  MicroBlaze, which needs Vivado and a soft CPU.
- **Reusable Verilog SD cores** exist — ZipCPU's `sdspi`, WangXuan95's
  `FPGA-SDcard-Reader` — but both are GPL, which is a decision to make rather
  than a dependency to add.

What this design deliberately does not do: no writes, no multi-block reads, no
filesystem, and no byte-addressed cards. Block zero is at address zero whichever
way a card is addressed, so CMD58's answer (kept, and visible via `sdExtra`) is
recorded but not acted on; reading any other block would have to branch on it.

## The board's own hardware

The Basys3 carries 16 LEDs, 16 slide switches, five push buttons, a four-digit
seven-segment display, and a serial link to the host that needs no extra hardware
at all. Four namespaces divide the code that drives all of that and
the modules plugged into it, and the rule for each is worth stating because it
decides where the next thing goes:

| Namespace | Contains | Knows about |
| --- | --- | --- |
| `Protocol.*` | How to talk on a wire: `Protocol.SPI`, `Protocol.UART`, and `Protocol.I2C` when it is wanted | Timing and framing, not devices |
| `Peripheral.*` | How to drive or read a class of device: `Peripheral.SevenSegment`, `Peripheral.Button` | Devices, not boards — every timing is an argument |
| `Pmod.*` | One module per add-on you can plug into a Pmod header: `Pmod.SdCard` | Its own protocol, not which header it is on |
| `Basys3` | This board: its clock domain, the width of each thing on its pins, and the cycle counts that make those blocks concrete | Everything, and nothing reusable |

That is the same split `Blinky` already makes between its parameterised circuits
and its `topEntity`, applied one level up: a test can instantiate `debounce 3`
and simulate it in fifty cycles, while the board says `debounce settle` and means
five milliseconds.

Two modules sit outside all four on purpose, unprefixed. `Ascii` is about text, not
about a wire, a class of device, or something you can plug into a header. `Serial`
is the convenience layer over `Protocol.UART` and `Ascii`: the front door to the
host link, which is a thing a design uses rather than a thing a wire has. Pushing
it into `Protocol.*` would make a framing module depend on text, and forcing either
into one of the four would only make the table mean less. See
[Writing to the host](#writing-to-the-host).

**LEDs** need no logic — `Basys3.Leds` is a `BitVector 16` and the register drives
the pin. **The display** is `Peripheral.SevenSegment`: `sevenSeg` decodes a nibble
to active-low cathodes, `display` scans any number of digits, and `hexDigits`
splits a word into them least-significant-first. **Buttons and switches** are
mechanical contacts, and `Peripheral.Button` deals with the two separate problems
that creates:

- They change whenever a finger says so, not when the clock says so. A single
  register sampling one can settle to neither high nor low and fan that out to
  logic that then disagrees with itself. `synchronise` spends two flip-flops to
  prevent it. `Protocol.UART` has the same problem with its receive pin and spends
  the same two flip-flops inline, rather than importing a button driver — a bus
  master depending on `Peripheral.*` would invert the table above, and one shared
  line is not enough to justify a namespace to put it in.
- They bounce: the metal makes and breaks several times over a few hundred
  microseconds, so anything counting edges sees one press as a handful.
  `debounce` waits for the input to hold still — one shared counter per value
  rather than one per bit, which is what makes `bank` affordable for all sixteen
  switches at once.

`contact` is the whole chain for one button, returning the steady level and a
one-cycle pulse per press; `rising` and `falling` are exposed separately. On this
board the timing to hand them is `Basys3.settle`, 5 ms — a number rather than a
pre-applied circuit, so each `topEntity` supplies it and a test can substitute a
period it can afford to simulate.

`constraints/Basys3-Inputs.xdc` has the pins for the switches and the four outer
buttons, kept out of the default constraint set: naming ports the netlist does not
have is at best noise. Add it to a design's `XDC` list once that design's
`topEntity` actually takes them. btnC is not in it — it is the reset, already
assigned in `constraints/Basys3.xdc`. `DESIGN=io` is the one design that takes
them, and it adds `constraints/Basys3-Uart.xdc` alongside for the same reason:
`XDC` is a list, one opt-in file per group of pins a design either has or has not.

### The switch-and-button demo

`make bitstream DESIGN=io && make flash DESIGN=io` builds `examples/src/IoDemo.hs`, which
exists to exercise all of the above on real hardware — it is the only design that
uses the switch and outer-button pins at all.

Run on the board, both directions, not just in simulation: the greeting and the
counter reports arrive in a terminal, and `k`/`j` typed at the host step the
counter and the display. That makes the whole `Protocol.UART` module hardware-
verified — the divisor, LSB-first framing, and the receiver's mid-bit sampling.

| Input | Effect |
| --- | --- |
| Slide switches | Mirrored onto the 16 LEDs above them, through `bank` |
| btnU | Counts the displayed 16-bit value up by one |
| btnD | Counts it down by one |
| btnR | Loads whatever the switches read |
| btnL | Clears it to zero |
| btnC | Resets the domain: the board greets the host and reports `0000` |
| `k` or `K` from the host | Counts up by one — btnU from the keyboard |
| `j` or `J` from the host | Counts down by one — btnD from the keyboard |
| A hex digit from the host | Shifts the counter left four bits and drops that nibble in |

The counter is shown as four hex digits, so btnR is a check of the switches
against the display: set a value, press btnR, and the digits should read what the
LEDs are showing. One press stepping the count by exactly one is the claim
debouncing exists to make — an unconditioned button would jump several counts per
press. Pressing two things at once is defined rather than accidental: clear beats
load beats up beats down beats the host, so the person at the board always
outranks the person at the keyboard.

Out of reset the board greets the host, and then reports the counter:

```
Hello. To increase/decrease the counter, send 'k' or 'j' - or use the Up/Down buttons.
```

The greeting is the smaller of the two checks and the one to read first: it needs
nothing to be true about the counter, the switches or the buttons for its letters
to be legible, so if it arrives intact then the pins, the divisor and the
terminal's baud rate are all right and whatever else is wrong is further in. It
doubles as the instructions, which is the cheapest place to put them — a link that
explains itself needs no README open beside it. It comes from `say $(ascii …)`; see
[Writing to the host](#writing-to-the-host) below.

The length is not free: 88 bytes is about 7.6 ms on the wire, and the greeting wins
the transmitter outright, so the first counter report waits that long. Nothing is
lost — the reporter latches its value and holds it — but a keystroke in the
first few milliseconds after reset is answered late rather than at once. The tests
derive their timing from `greeting` for exactly this reason, so rewording it moves
the traces instead of breaking them.

Whenever that counter changes, from any of those sources, the design says so on
the serial link: four ASCII hex digits and a CR LF. Typing `beef` into the
terminal therefore produces

```
000B
00BE
0BEE
BEEF
```

while the display walks through the same four values. That the terminal and the
display always agree is what makes the link self-checking — a wrong baud rate
garbles the text while the display stays right — and it is what `stack test`
asserts, by decoding the design's own transmit pin with a second `uartRx`.

`k` and `j` step the counter up and down, the directions they mean in `vi` and
`less`. They are btnU and btnD from the keyboard, which makes them the easiest
check that the receive path works at all: hold `k` down and the display should
climb at the terminal's auto-repeat rate, one step per keystroke and not two.

### Nothing here waits for the host

Worth stating plainly, because the software habit is to *read* a byte: `uartRx`
reports `Just byte` for exactly the one cycle a frame completes on, and `Nothing`
every other cycle. Nothing blocks on it anywhere. A keystroke is an input to that
cycle's counter update in the same way a debounced button press is, and a cycle
with no byte in it is just a cycle whose guard does not fire. So the display goes
on scanning, the LEDs go on mirroring the switches, and a keystroke landing in the
middle of an outgoing report is harmless — receive and transmit share no state.

That is also why one byte is one whole request rather than a command with
arguments. There is nothing to remember between frames, so nothing can be
half-said and there is no partial command needing a timeout. A multi-byte command
language would need that state, and it is the point at which this design would
stop being a demo.

The counting is exact even when the reporting is not. At 115200 a byte takes about
87 µs to arrive and a six-byte report about 520 µs, so a fast paste outruns the
reporter — but each byte still lands on its own cycle and still steps the counter,
and the coalescing below means the last report carries wherever the counter
actually ended up. Steps are never lost; intermediate *reports* are.

Two consequences of sharing one 16-bit value between a keyboard and four buttons
are worth naming, because they are the reason `Serial.report` has the shape it does:

- **The reported value is frozen when the report starts.** Six bytes take sixty
  bit periods, and a paste arrives a byte every ten, so without that freeze one
  report could describe two different numbers.
- **Changes are coalesced, not dropped.** It compares the counter against the value
  the host was last *told*, not against what it was last cycle, so a burst of
  changes during a report produces exactly one more report afterwards — carrying
  the value the board ended up at. The host is therefore sometimes late but never
  stale. That comparison also produces one report straight out of reset, because
  what the host has been told starts as `Nothing`, which no value is equal to — a
  free way to check the link without touching the board.

The decimal point is the one diagnostic: it lights, and stays lit, if a frame ever
arrives with its stop bit low. That is what a terminal set to the wrong speed
looks like from this end, and the alternative symptom is silence.

## Talking to the host

### UART, not RS-232

**UART** is the framing: no clock on the wire, both ends agreeing on a bit period
in advance, and each byte sent as a low start bit, eight data bits **least
significant first**, and a high stop bit — 8N1, with the line idling high.
`Protocol.UART` is exactly that and nothing else. The bit order is worth saying
twice, because `Protocol.SPI` next door shifts most significant bit first: the two
buses genuinely disagree, and a transmitter that gets it wrong still produces
plausible-looking bytes.

**RS-232** is the electrical standard that historically carried it — ±12 V on a
DB-9. The Basys3 has no RS-232 transceiver at all: the FT2232HQ does USB on one
side and hands the FPGA 3.3 V LVCMOS on the other. Digilent's `USB-RS232`
heading and their `RsRx`/`RsTx` port names are a nod to a cable this board does
not have; ours are `uart_rx` and `uart_tx`.

### One cable, two interfaces

The FT2232HQ is a two-channel part, and the two channels are doing different jobs
on the same connector (J4):

- **Channel A** is the USB-JTAG that `openFPGALoader` drives. That is `make flash`.
- **Channel B** is a USB-serial bridge wired into the fabric on two pins. That is
  `make monitor`.

So the one cable that already programs the board is also the terminal. The host
gets a `/dev/cu.usbserial-*` node for *each* channel — macOS sees two ordinary
serial devices and has no idea one of them is a JTAG adapter — so two things
follow, and both have bitten:

- **Only the second node carries the UART.** Picking channel A gives you a
  terminal that is wired to nothing and can never say a word. Which node is which
  is covered under [`make monitor`](#make-monitor).
- **The two targets do contend, but it depends which node.** Observed on this
  board, not reasoned from the datasheet:
  - A terminal on a **`cu.*`** node makes `make flash` fail with
    `unable to claim usb device` — *even on the channel flashing does not use*.
    The `cu` device takes `TIOCEXCL`, and that appears to cover the whole bridge
    rather than one channel. So: quit `screen` before flashing.
  - Something holding only the **`tty.*`** twin does not block a flash. The VS Code
    Serial Monitor does this, and two flashes ran clean with it attached.
  - That same `tty.*` opener does make a `cu.*` open fail with `EBUSY`. So the two
    terminals contend with each other even where neither blocks flashing, and
    `lsof` on the device shows nothing useful — the giveaway is the `tty.*` node's
    mtime being later than its siblings'.

  Nothing warns you either way, because from the bridge's point of view nothing is
  wrong.
- **Do not flash while a terminal is capturing.** `openFPGALoader` takes the device
  out from under it. A `screen -L` session dies and leaves a log full of NUL bytes,
  which reads like a design fault rather than a lost port — this cost an hour.

### The pins

| Our port | Pin | Schematic net | Digilent's name | Direction |
| --- | --- | --- | --- | --- |
| `uart_rx` | B18 | `UART_TXD_IN` | `RsRx` | input — host to FPGA |
| `uart_tx` | A18 | `UART_RXD_OUT` | `RsTx` | output — FPGA to host |

The net names are from the bridge's point of view, which is why the net called
`UART_TXD_IN` is our *input*. Getting this backwards produces a dead link and no
other symptom, so it is worth the cross-check: both assignments are in
`constraints/Basys3-Uart.xdc`, opt-in for the reason `Basys3-Inputs.xdc` is, and
confirmed against Digilent's master XDC and against their own `Projects/GPIO`,
which binds a port declared `out` to A18.

RTS and CTS are not brought out to the FPGA, so there is no hardware flow control
in either direction — see below.

### Baud rates

`Protocol.UART` takes cycles per bit minus one, the way `spiMaster` takes a half
period. At 100 MHz, 100e6 / 115200 = 868.06, so each bit is 868 cycles and the
divisor is 867 — `Basys3.baud115200`. The realised rate is 115207 baud, 0.006%
fast.

What that error has to beat: the receiver samples the stop bit nine and a half bit
periods after the start edge, and a sample stays inside its bit while the
accumulated error is under half a bit, so the two ends together have just under 5%
to play with. 0.006% leaves effectively all of it to the host.

`Unsigned 16` bottoms out at 65535 cycles a bit, which is 1526 baud: every
standard rate from 2400 up fits, 1200 would need a wider counter. Other rates are
`round (100e6 / baud) - 1`.

### `make monitor`

```bash
make monitor                                     # find the port, open screen
make monitor SERIAL=/dev/cu.usbserial-XXXX1      # when the guess is wrong
make monitor BAUD=9600                           # deliberately wrong, to see dp light
```

**Which node is the UART.** The target lists `/dev/cu.usbserial-*`, sorts, and
takes the **last**. That is not a guess about naming so much as a way of not having
to make one: how the FTDI driver spells the channel depends on its vintage, and
this machine gives

```
/dev/cu.usbserial-210183B039D40    <- channel A, JTAG
/dev/cu.usbserial-210183B039D41    <- channel B, the UART
```

— digits, not the `A`/`B` this file used to claim. Sorting covers both, since `B`
comes after `A` exactly as `1` comes after `0`. The earlier version matched a
literal `B`, found nothing, and fell back to the *first* node, which is channel A:
a terminal on the JTAG side, silent for ever, and holding the device open so
`make flash` could not run either. Verified on the board: the last node is the one
that carries the greeting. `SERIAL=` overrides it, and with nothing plugged in the
target prints what to check and exits non-zero.

`cu.*` rather than `tty.*` because the call-out device does not block waiting for
carrier detect, and with no flow-control lines brought out there is no carrier to
wait for.

`screen` is the default because it ships with macOS and this target exists to
answer "is the wire alive" without installing anything — `picocom`, `minicom` and
pyserial are none of them present by default. The target `exec`s it and nothing
else, so `make monitor` *is* `screen <port> 115200`; anything taking `PORT BAUD`
positionally drops in with `MONITOR=`.

**Quit with `Ctrl-a` `k` `y`.** Worth knowing what not to press: `Ctrl-a` `d`
*detaches*, leaving the session alive and still holding the port, and closing the
terminal window does the same. Either way the next `make flash` fails with
`unable to claim usb device` and there is no window left to explain why — the
symptom appears on the target you did not touch. `screen -ls` lists what is still
running, `screen -r` reattaches, `screen -X -S <name> quit` kills it, and
`screen -wipe` clears the dead socket afterwards.

What to expect, having flashed `DESIGN=io`:

```
Hello. To increase/decrease the counter, send 'k' or 'j' - or use the Up/Down buttons.
0000
        <- press btnU
0001
```

— the greeting and `0000` the moment the board resets, then a line every time the
counter moves. Set the switches, press btnR, and the same four characters appear in
both places. Press `k` and `j` to count up and down from the keyboard. Type `beef`
and watch the display fill up from the right.

### Writing to the host

`src/Serial.hs` is the front door, and it is deliberately shaped like Arduino's
`Serial`: one named thing you talk to, formatting supplied, and nothing said about
who owns the transmitter. The whole transmit side of `IoDemo` is these two lines:

```haskell
(uartOut, heard) = serial baud115200 rxPin
                     (say greeting atReset `before` report word count)
```

A greeting once, the counter whenever it changes, both directions wired up. What
the rest of this section is about is the three ways that is *not* `Serial.print`,
because each of them is a real difference and not a missing feature.

**Nothing blocks.** There is no call to return from: a string occupies the wire for
as long as its bytes take to leave — 88 bytes of greeting is 7.6 ms at 115200 — and
the design carries on meanwhile. So `report` watches a signal instead of being
called, which is why the counter is reported by *changing*, from a button or a
keystroke or anything else, with nothing in the counter's own logic aware that a
report exists.

**Nothing is buffered.** `Serial.print` hands bytes to a queue. Here each client
holds its own place in its own spelling, so a value that moves faster than the wire
coalesces into one later report rather than filling a FIFO. There is no queue
anywhere in this design, in either direction.

**Each use is its own circuit.** Two `report`s are two sequencers, not two calls to
a shared one. They are cheap — about twenty flip-flops each — but they are not free,
and a loop cannot make one. The same goes for `say`, and its string is a constant,
so it costs LUTs and not memory: the right trade for a greeting, while a few hundred
bytes is where block RAM and a `MemBlob` start being the better answer.

Everything with bytes to hand over has one shape, which is what makes the line above
compose:

```haskell
type Source dom =
  Signal dom Bool                                      -- would a byte be taken?
  -> (Signal dom (Maybe (BitVector 8)), Signal dom Bool)  -- the byte, and is there more
```

`say` and `report` are both `Source`s once their own arguments are applied, and
`before` puts two of them on one transmitter with the left one winning: the right one
is simply told the transmitter is busy until the left runs out, which loses nothing
because a source holds its byte until the offer is taken. It is associative with
`silent` as its identity, so a third client is `foldr before silent [...]` rather
than a priority tree somebody has to write. `atReset` is the one-cycle pulse that
makes the greeting a greeting.

One rule makes all of that work, and it is the only way to misuse a `Source`:
**whether there is more to come must come out of a register, not from this cycle's
"was it taken"**. `say` and `report` are both Moore machines, so both hold to it; a
Mealy source would turn `before` into a combinational loop, and Clash would say so.

The spellings are separate, in `src/Ascii.hs`, and pure: `ascii` turns a string
literal into a `Vec` at compile time (Template Haskell, because a `Vec` carries its
length in its type — and because that is the last moment at which a character it
cannot represent is an error rather than a quietly truncated byte), `hex` spells a
word most significant first, and `line` puts CR LF on the end. A format is then a
one-liner whose signature settles the digit count:

```haskell
word :: BitVector 16 -> Vec 6 (BitVector 8)
word = line . hex
```

Keeping those pure is what lets `stack test` check a format with a list comparison
instead of a trace. Decimal is the obvious omission: on an Arduino `print` divides
for free, and here it needs double-dabble or a divider, so it is a decision with a
LUT cost rather than a spelling.

### No flow control

Neither end can ask the other to wait, so a design that needs back-pressure needs
an application-level protocol. This one does not: it has one kind of byte to listen
for and two things to say, and the second is settled by `before` rather than by a
queue. The host can outrun the reporter, and the coalescing above is the answer —
the last report always carries the value the board actually holds.

### How it is put together

| Path | Purpose |
| --- | --- |
| `src/Protocol/UART.hs` | 8N1 transmitter and receiver, bit period as an argument |
| `src/Serial.hs` | The front door: `serial`, `Source`, `say`, `report`, `before` |
| `src/Ascii.hs` | Pure text: `ascii`, `hex`, `hexChar`, `hexNibble`, `line` |
| `src/Basys3.hs` | `baud115200`, the divisor for this board's clock |
| `examples/src/IoDemo.hs` | The greeting, `word` for how this design spells its counter, and `typedAs` for what the host may ask |
| `constraints/Basys3-Uart.xdc` | B18 and A18, and their timing exceptions |

`make sim` does not cover this: only `blinky` has a `TestBench` annotation. The
tests close the loop in Haskell instead — the transmitter's line into the
receiver with frames back to back, hand-built frames into the receiver for the
glitch and framing-error cases, each `Source` driving a real transmitter into a
real receiver so what comes out is what a terminal would see, and the whole design
driven from a hand-built frame with its own transmit line decoded back.

## Layout

Two Stack packages, and the split is the point:

- **`blinky`** (this directory, `src/`) — the reusable half. It knows nothing about
  any particular design.
- **`blinky-examples`** (`examples/`) — the designs, one module each and the only
  place a `topEntity` lives, plus the Clash driver that compiles them and the test
  suite that exercises them. All three need a design in scope, which is why they
  share a package.

The dependency runs one way, and it is the package graph that says so rather than a
convention: `import IoDemo` inside `src/` does not resolve, because `blinky` does
not depend on `blinky-examples`. `clash-common.yaml` holds the extensions,
plugins and unfoldings both packages' hardware components need, included into each
with `<<: !include` so the two cannot drift apart.

The one thing to know about this shape: the `clash` and `clashi` executables live in
`examples/bin/`, not at the top level, because the Clash compiler resolves the
module it is handed — `IoDemo`, `SdDemo` — through its own package environment. An
executable in `blinky` could not see one. Splitting the designs into an *internal*
library was tried first and does not work at all: cabal registers one as a hidden
package, and the GHC session inside `clash` cannot load a module out of it.

| Path | Purpose |
| --- | --- |
| `src/Ascii.hs` | Text as bytes, all of it pure: a string literal as a `Vec`, hex digits, a line ending |
| `src/Basys3.hs` | This board: clock domain, prescaler, pin widths, contact timings |
| `src/Peripheral/SevenSegment.hs` | Digit decoder, scanning driver, word-to-digits |
| `src/Peripheral/Button.hs` | Synchroniser, debouncer, edge pulses — for any contact |
| `src/Pmod/SdCard.hs` | The Pmod SD: SD initialisation and a single-block read |
| `src/Protocol/SPI.hs` | Byte-oriented SPI mode-0 master, independent of what is on the other end |
| `src/Protocol/UART.hs` | 8N1 transmitter and receiver, bit period as an argument |
| `src/Serial.hs` | The host link as one thing you talk to: `serial`, and the `Source`s that feed it |
| `examples/src/Blinky.hs` | The blinker: BCD counter, `topEntity`, `testBench` |
| `examples/src/IoDemo.hs` | The switch-and-button demo: switches on the LEDs, buttons on a counter, that counter on the serial link |
| `examples/src/SdDemo.hs` | The SD design's board wrapper: pins, LEDs, display |
| `package.yaml`, `examples/package.yaml` | The two package descriptions, and the source of truth: Stack runs hpack on each, which generates the `.cabal` file beside it |
| `clash-common.yaml` | The hardware stanza both packages include: extensions, the three type-level plugins, unfoldings |
| `stack.yaml` | The snapshot — and therefore the Clash and GHC versions — and the list of packages |
| `examples/test/Spec.hs` | Haskell-level simulation run by `stack test` |
| `examples/test/Pmod/FakeSdCard.hs` | A simulated SD card, so the controller is testable without one |
| `constraints/Basys3.xdc` | Pin and timing constraints for the board's own I/O |
| `constraints/Basys3-Inputs.xdc` | The switches and outer buttons; opt-in, see above |
| `constraints/Basys3-Uart.xdc` | The two USB-UART pins; opt-in, likewise |
| `constraints/PmodSD.xdc` | The Pmod SD's timing exceptions and pinout notes, whichever header it is on |
| `constraints/PmodSD-J{A,B,C}.xdc` | The six pins, one file per header; `PMOD` picks one |
| `syn/openxc7.Containerfile` | Native arm64 image with yosys, nextpnr-xilinx and prjxray |
| `syn/openxc7.mk` | The bitstream flow, run inside that image |
| `test/dump.v` | `$dumpvars` root module, compiled in so `make sim` writes a VCD |
| `test/verilator.vlt` | One documented lint waiver, per design, for Clash's 64-bit vector indices |
| `test/surfer-commands.txt` | Signals Surfer preselects when opening a waveform |
| `examples/bin/Clash.hs`, `examples/bin/Clashi.hs` | Entry points so `stack run clash` / `clashi` can see the designs |

The top-level `test/` and `examples/test/` are two different things, and the split
follows which tool reads them: `test/` holds fixtures for Verilator and Icarus,
`examples/test/` is the Haskell test suite GHC compiles.

### Design notes

`blinky` takes both periods as arguments rather than hard-coding them.
`topEntity` applies the real values — `99_999_999`, a pulse every 100e6 cycles
= 1 s at 100 MHz, each pulse inverting all 16 LEDs; and `99_999`, holding each
digit lit for 1 ms so the display refreshes at 250 Hz — while both test benches
use 2 and 100, so twelve simulated cycles cover two blinks with the scan parked
on one digit. `rotator`, the one-hot walking pattern, is kept as an alternative
and still covered by `stack test`; swap it in for the blink to get a chase.

The count is kept as four BCD digits rather than a binary number, so advancing it
is a ripple of `+1` and the modulo 10000 wrap is just the carry falling off the
end — no division by ten to extract digits. `stack test` checks `bcdSucc` against
decimal arithmetic for all 10 000 values.

The display is common anode with transistor drivers, so `seg` (CA…CG), `dp` and
`an` (the digit enables) are all **active low**, and only one digit is lit at a
time: `display` walks the four anodes, putting the matching digit's cathode
pattern out with it. `an[0]` is the rightmost digit. Port names in the generated
Verilog come from the `Synthesize` annotation on `topEntity` and must match the
XDC: `clk`, `rst`, `led[15:0]`, `seg[6:0]`, `an[3:0]`, `dp`.

The `Basys3` domain declares an **active-high asynchronous** reset, matching
btnC, which reads high when pressed. The domain's `vPeriod` is also where the
clock period lives: Clash emits it as `blinky.sdc` next to the generated HDL, so
`constraints/Basys3.xdc` only assigns the W5 pin and never repeats the 10 ns.

Pin assignments were taken from Digilent's
[Basys3_Master.xdc](https://github.com/Digilent/digilent-xdc) — cross-check
against it when you add anything the board has that these designs do not use yet,
VGA and the USB-HID host port being what is left.
