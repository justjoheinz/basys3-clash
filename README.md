# basys3 — Clash on the Digilent Basys3

A library of the Basys3's own hardware, written in Haskell with
[Clash](https://clash-lang.org) and built on Apple Silicon: the display's
multiplexing, the buttons' debouncing, a UART at the baud rate the board's bridge
wants, base ten and base sixteen, an SD card over SPI, and the pin names and clock
period that the toolchain needs and that nobody should be retyping. Closer to an
Arduino library than to a demo: the parts are meant to be picked up and used, and
the four designs here are what using them looks like.

The board is a Digilent Basys3: AMD Artix-7 `xc7a35tcpg236-1`, 100 MHz clock on
pin W5, 16 LEDs, a four-digit seven-segment display, and an FT2232HQ that is both
the USB-JTAG programmer and a USB-serial bridge.

A design that lights the switches, shows them in hex on the display and prints them
in decimal to your terminal is one import and four lines of circuit:

```haskell
import Basys3.Board

sketch sw rxPin = bundle (leds, withPoint faulty (showHex leds), tx)
 where
  leds = switches sw
  (tx, heard) = host rxPin (say $(ascii "Flip a switch.\r\n") atReset
                              `before` report (line . dec @5) leds)
  faulty = latch (rxError <$> heard)
```

Not a settle time, not a refresh rate, not a baud divisor: `switches`, `showHex`
and `host` are those numbers already applied. See
[The smallest design](#the-smallest-design) for the file this comes from, and
[One import](#one-import) for what that import brings.

Four designs are here, and every target takes `DESIGN=` to pick one (`make
designs` lists them):

- `DESIGN=sketch` — `Sketch` is the smallest complete design and the one to copy:
  the switches on the LEDs, their value in hex on the display and in decimal in
  your terminal, with no cycle counts anywhere in it. See
  [The smallest design](#the-smallest-design).
- `DESIGN=blinky` — the default, and where this started: all 16 LEDs blinking
  together, one second on and one second off, and nothing else. It is also the only
  design with a generated test bench, so `make sim` and `make waves` mean this one.
- `DESIGN=sd` — `Sd` brings up an SD card over SPI on a Digilent Pmod SD and
  reads block zero, showing the result on the same LEDs and display. See
  [Reading an SD card](#reading-an-sd-card).
- `DESIGN=io` — `Io` puts the slide switches on the LEDs and the four outer
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
make designs    # list designs, with what each one does
make test       # Haskell-level simulation, no HDL simulator involved
make repl       # interactive Clash REPL
make verilog    # generate Verilog into verilog/Blinky.topEntity/
make sim        # run the generated HDL test bench in Icarus Verilog
make waves      # open the waveform in Surfer
make lint       # Verilator lint over the generated Verilog

make openxc7-image  # one-off: build the synthesis toolchain image
make bitstream      # yosys + nextpnr-xilinx + prjxray -> build/openxc7/blinky.bit
make flash          # load it onto the board

make bitstream DESIGN=sketch && make flash DESIGN=sketch   # the smallest design
make bitstream DESIGN=sd     && make flash DESIGN=sd       # the SD card demo
make bitstream DESIGN=io     && make flash DESIGN=io       # switches and buttons

make monitor    # serial terminal on the board, for DESIGN=sketch or DESIGN=io
                # close it again before the next make flash: one USB device
```

`DESIGN` picks the top-level module, the entity name the bitstream is called after,
and which pin constraint files are used. It applies to every target except
`make test`, which always runs every check, and `make monitor`, which only opens a
terminal. `make sim` and `make waves` only work for `blinky`: it is the design with
a `TestBench` annotation.

### Adding a design

Two new files, and nothing to edit:

1. `examples/src/Mirror.hs` — a module with a `topEntity` and a `Synthesize`
   annotation. [The smallest design](#the-smallest-design) is the template.
2. `examples/design/mirror.mk` — four lines saying which module it is, what its
   annotation named the entity, which `constraints/` files its ports need, and one
   line of description for `make designs`.

`make bitstream DESIGN=mirror` then works, as does every other target. The
`Makefile` finds designs by listing that directory, so it needs no changes, and
neither does `package.yaml`: hpack globs `examples/src`, so a new module is picked
up by being there.

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
`count`) and the blink phase `lit`, so the window opens on something readable
rather than empty.

For GTKWave, whose flags differ, override them:

```bash
make waves WAVE_VIEWER=gtkwave WAVE_CMDS=
```

### Simulation, two ways (plus hardware)

1. **Haskell level (`make test`, `make repl`)** — the fastest loop, and the
   reason to use Clash at all. `Signal dom a` is an infinite stream, so you
   simulate by sampling it:

   ```haskell
   sampleN @System 20 (withClockResetEnable clockGen resetGen enableGen (blinky 2))
   ```

2. **Generated HDL (`make sim`)** — `testBench` in `examples/src/Blinky.hs` is compiled
   to a real Verilog test bench with assertions. This is what catches divergence
   between the Haskell semantics and the emitted RTL.

   Note that a mismatch makes Clash's `outputVerifier` print and call
   `$finish`, and `vvp` still exits 0, so `make sim` greps the log and reports
   PASS/FAIL itself. That was checked against a deliberately wrong expected
   value.

3. **The actual FPGA** — `make bitstream && make flash`.

### "Ambiguous type variable ‘dom0’"

Every circuit here is written against `HiddenClockResetEnable dom` for some `dom`,
and a simulation has to say which one. Leave it out and the error is not about
clocks at all:

```
error: [GHC-39999]
    • Ambiguous type variable ‘dom0’ arising from a use of ‘sampleN’
      prevents the constraint ‘(KnownDomain dom0)’ from being solved.
      Probable fix: use a type annotation to specify what ‘dom0’ should be.
```

The fix is to name the domain at the point of simulation, either on the call or on
the circuit:

```haskell
sampleN @System 20 (withClockResetEnable clockGen resetGen enableGen (blinky 2))

sampleN 900 (withClockResetEnable clockGen resetGen enableGen
               (uartLoop :: Signal System UartRx))
```

`System` is Clash's own test domain, and it is what both suites simulate in — not
`Basys3`, because a 100 MHz period would make every timing in them a real one. So
`clockGen` and `resetGen` are the only things that need the annotation: everything
they drive gets its domain from them.

Local bindings inside a circuit do *not* need one. `MonoLocalBinds` — on by
implication, since `TypeFamilies` is in `clash-common.yaml` — keeps an unannotated
`where` binding monomorphic instead of generalising it, so its domain flows in from
whatever it is used by, feedback loops and tuple patterns included. This project
carried annotations on eight such bindings for a while, each with a comment about
pinning the domain; removing all eight changed nothing, under GHC 9.12.4 with these
extensions. A local signature is worth writing when the *size* of something is
otherwise unpinned — `Serial`'s state length is the example — and not for the domain.

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
simulation says they should. It produces `blinky.bit` (about 2 192 130 bytes, the
fixed frame count for this part plus a header), nextpnr reports 218.91 MHz against
the 100 MHz constraint, and all 18 constrained pins resolve to real pads — 16
`IOB33_OUTBUF` for the LEDs, 2 `IOB33_INBUF_EN` for `clk` and `rst`, with the clock
going on through one `BUFGCTRL` — appearing in the FASM with `LVCMOS33` drive and
slew settings, which is what confirms the `PACKAGE_PIN` constraints were actually
applied rather than silently ignored. Repeated runs produce byte-identical FASM and frames, so place-and-route
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

Expected behaviour: all 16 LEDs on for one second, off for one second. Pressing
the centre button (btnC) holds them dark, and the blinking restarts on release.

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

Because `Failed` is a passing state, `Sd` holds on to it and to the diagnostic
word, with `latch ((== Failed) . sdStage <$> out)`; anything else built on
`Pmod.SdCard` wants the same line to report a failure.

This has been run on the board, not just in simulation: with the Pmod on JA and
an empty socket the display reads `F1FF`, and a formatted microSD card brings up
`55AA`. nextpnr reports 148.37 MHz against the 100 MHz constraint, and the six
Pmod pins were cross-checked against prjxray's `package_pins.csv` — `sd_cs` at
`IOB_X1Y93` is J1, and so on — which is what confirms the second `.xdc` was
applied rather than silently ignored.

### How it is put together

| Module | Role |
| --- | --- |
| `Protocol.SPI` | A byte-at-a-time SPI mode-0 master. Knows nothing about SD — not even that a chip select exists. |
| `Pmod.SdCard` | The protocol: CMD0, CMD8, CMD55/ACMD41, CMD58, CMD17, and the timeouts. |
| `Sd` | The board wrapper — pins, LEDs, display. |
| `spec/FakeSdCard.hs` | A pretend card: a real SPI slave that answers like one. Test code, so not in the library. |

`FakeSdCard` is why this could be written without a board in the loop. It lives in
`spec/` rather than in `src/`, because a library has no business shipping a double
of a part nobody's design contains — which does mean it is the library suite's
alone, and that writing your own controller means writing your own card. `make
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
| `Protocol.*` | How to talk on a wire: `Protocol.SPI`, `Protocol.UART`, `Protocol.I2C` | Timing and framing, not devices |
| `Peripheral.*` | How to drive or read a class of device: `Peripheral.SevenSegment`, `Peripheral.Button` | Devices, not boards — every timing is an argument |
| `Pmod.*` | One module per add-on you can plug into a Pmod header: `Pmod.SdCard` | Its own protocol, not which header it is on |
| `Basys3` | This board: its clock domain, the width of each thing on its pins, and the cycle counts that make those blocks concrete | Everything, and nothing reusable |

That is the same split `Blinky` already makes between its parameterised circuit
and its `topEntity`, applied one level up: a test can instantiate `debounce 3`
and simulate it in fifty cycles, while the board says `debounce settle` and means
five milliseconds.

`Basys3` exports both halves of that, deliberately:

- **The circuits, with this board's numbers already in them** — `switches`,
  `button`, `pressed`, `showHex`, `withPoint`, `host`. These take a signal and give
  one back, and a design built from them mentions no cycle counts at all.
  [`Sketch`](#the-smallest-design) is one.
- **The same numbers, bare** — `settle`, `dwell`, `baud115200`, for the circuits
  taken directly from `Peripheral.*` and `Serial`. Five milliseconds is 500,000
  cycles, and a test that simulates them is a test nobody runs, so a design meant to
  be tested takes its timings as arguments and its `topEntity` is the only place the
  real ones appear. `Io` is that shape; it is why it has a test suite and
  `Sketch` does not.

Reach for the first; write the second when the logic gets interesting enough to be
worth testing.

### One import

`Basys3.Board` is `Basys3`, `Ascii`, `Serial`, `Peripheral.Button`,
`Peripheral.SevenSegment`, `Latch` and `Clash.Prelude` together, and it is what a
design should import. Every demo here uses it; neither test suite does, because a
test that pins a byte should also pin which module spelt it — and a name moving
between modules is something those files ought to notice.

Its one cost is that plain words are taken — `dwell`, `settle`, `switches`,
`button`, `pressed`, `host`, `report`, `line`. `-Wall` reports a local binding that
shadows one, and the warning is usually right: a circuit taking its own settle time
as an argument is doing that so as *not* to use the board's. The demos here call
theirs `hold`, `press` and `diagnostic` for that reason.

The `Pmod.*` modules are deliberately left out. A Pmod is something bought
separately and plugged in, so the design using one says which: `Sd` imports
`Basys3.Board` and `Pmod.SdCard`.

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
board the timing to hand them is `Basys3.settle`, 5 ms. `Basys3.switches` and
`Basys3.button` are `bank` and `contact` with that number already applied, which is
what a design wants; the number stays exported for the design that takes its own so
a test can substitute a period it can afford to simulate.

`constraints/Basys3-Switches.xdc` and `constraints/Basys3-Buttons.xdc` have the
pins, one file per group, and neither is in the default constraint set: a design's
`XDC` list is meant to say what its pins are. Add a file once that design's
`topEntity` actually takes those pins — `DESIGN=io` takes both, `DESIGN=sketch` only
the switches. btnC is in neither — it is the reset, already assigned in
`constraints/Basys3.xdc`, which holds only the clock and the reset and lists the
rest.

That is the rule for the whole directory: `XDC` is a list, one opt-in file per group
of pins a design either has or has not, and `src/Basys3.hs` exports one `PortName`
or port group per file. So a design's `XDC` list and its `Synthesize` annotation
carry the same groups in the same order, and can be read against each other.

How much of that the toolchain enforces, measured rather than assumed — and
nextpnr-xilinx is laxer here than Vivado would be:

- A **forgotten** file is caught, but late and obscurely: not at placement but at
  FASM generation, as `ERROR: port dp of type PAD has no IOSTANDARD property`. The
  message names the port, not the file.
- A **spare** file is ignored in silence — no error, no warning — because its
  constraint names a port the netlist does not have. So the lists cost nothing to
  over-specify and prove nothing by being long, which is why they are kept tight.

### The smallest design

`make bitstream DESIGN=sketch && make flash DESIGN=sketch` builds
`examples/src/Sketch.hs`: flip the switches, and the LEDs follow them, the display
shows the same 16 bits as four hex digits, and a line of decimal arrives in
`make monitor`. It is about twenty lines, and it is the file to copy when starting
something.

What it demonstrates is mostly what it does *not* contain: one import, no cycle
counts, and no port-name strings. Its whole body is

```haskell
sketch sw rxPin = bundle (leds, withPoint faulty (showHex leds), tx)
 where
  leds        = switches sw
  (tx, heard) = host rxPin (say $(ascii "Flip a switch.\r\n") atReset
                             `before` report (line . dec @5) leds)
  faulty      = latch (rxError <$> heard)
```

`switches` debounces, `showHex` scans the display at 250 Hz, `host` runs the UART at
115200 baud, `latch` is the one flip-flop that remembers a one-cycle error for long
enough to be seen, and `withPoint` uses the decimal point as a lamp for a bad link —
none of which the design has to say a number for. `Io` below is the same board
written the other way, with every one of those timings as an argument so it can be
tested in a few hundred cycles.

The only arithmetic in it is base ten, and that is also its whole critical path:
place-and-route puts the design at 125 MHz against the board's 100, on the strength
of `Ascii.dec` alone. Written the way the double-dabble trick is usually explained —
as a four-bit add per step — the same design failed timing at 40 MHz; `Ascii`'s
`steps` is the one-level-of-LUTs form and the note explaining why.

### The switch-and-button demo

`make bitstream DESIGN=io && make flash DESIGN=io` builds `examples/src/Io.hs`, which
exists to exercise all of the above on real hardware — it is the only design that
uses the outer-button pins at all.

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

## The I2C bus

Nothing on this board is wired to an I2C bus, which is why none of the four designs
uses one — `Protocol.I2C` is here for the sensors and clocks and EEPROMs that are,
all of which arrive on two pins of a Pmod header. It is the third member of
`Protocol.*` and the one least like the other two.

### Open drain, which is most of it

Two wires, SCL and SDA, with a pull-up resistor on each, and every device on the
bus may only ever pull a line low or let go of it. Nothing drives high. That is
what lets a target answer on the same wire the master asked on, and it is why
`I2cOut` reports flags rather than levels:

```haskell
data I2cOut = I2cOut
  { i2cSclLow :: Bool          -- pull SCL down; False releases it
  , i2cSdaLow :: Bool          -- pull SDA down; False releases it
  , i2cDone   :: Maybe I2cReply
  , i2cIdle   :: Bool
  }
```

`openDrain` turns either flag into the `Maybe (BitVector 1)` that
`writeToBiSignal` wants — `Just 0` for driven, `Nothing` for released — because the
only value an open-drain output ever drives is zero. Both lines are therefore
`BiSignalIn` at the top level, read from and written to, which is the one part of
using this module that is not obvious; the module header has the wiring.

The same fact makes the bus trivial to model in a test. A line is high when nobody
is holding it down, so the whole of it is one `not` of a disjunction, and adding a
second device to a simulated bus is adding a term to that.

### One operation at a time

```haskell
data I2cOp = Start | Stop | Write (BitVector 8) | Read Bool
data I2cReply = Framed | Acked Bool | Fetched (BitVector 8)
```

`spiMaster` next door takes a byte and leaves chip select to whoever is using it,
because chip select is a wire beside the bus and says nothing about timing. A START
is the opposite: it *is* a particular edge in a particular place — SDA falling while
SCL is high — so a byte pipe that could not produce one would not be speaking I2C.
Hence the four operations. A transaction is however many of them it takes, offered
one per `i2cIdle`:

```haskell
[Start, Write (addressFor 0x48 False), Write 0x00,
 Start, Write (addressFor 0x48 True), Read True, Read False, Stop]
```

which is write-a-register-then-read-it, the shape almost every part wants. The
`Start` in the middle is a repeated START, and it is the same constructor: the
sequence it performs releases SDA, releases SCL, then pulls SDA low, which is a
fresh START from an idle bus and a repeated one from the middle of a transaction.
There is no way for a caller to pick the wrong one.

`Read`'s argument is the acknowledge the master sends *after* the byte: `True` means
another follows, `False` is the NACK that tells the target this was the last. Get
that backwards and a well-behaved target keeps talking through the STOP, holding
SDA down, and the bus wedges — which the pretend target in `spec/` models on
purpose.

### Quarters, and why a START gets halves

Each bit is four quarter-periods: SDA takes the bit's value while SCL is low, SCL is
released, the bit is sampled, SCL is pulled low again. Sampling happens halfway
through the high period rather than at either edge of it, which matters more than it
looks — the two input synchronisers on SDA mean a sample reads the line as it was
two cycles ago, so a sample point at the rising edge would be reading the low
period.

A START and a STOP are built out of *half* periods instead, and the arithmetic is
the reason. At 100 kHz the specification wants SCL high for 4.7 µs before SDA falls
and SDA low for 4.0 µs before SCL follows: 8.7 µs of a 10 µs bit, which no
arrangement of quarters can hold. Halves give 5 µs and 5 µs.

The realised SCL is therefore a little slower than `f / (4 * (quarter + 1))`, and
deliberately so: the high period is timed from the cycle SCL *reads* high, not from
the cycle it was released, so the pull-up's rise time and the synchronisers are
added to each bit rather than stolen from it. `spec/` checks that as a number — every
high period is two quarters plus exactly two cycles.

### Clock stretching

A target that needs time holds SCL down after the master has released it. The clock
is only high when the wire is high, so the master has to watch SCL as well as drive
it, and that is the whole reason `i2cMaster` takes it as an input. Two of the ten
phases are the ones where SCL is meant to be up and is being timed, and in both of
them the countdown simply does not run until the line reads high.

It waits indefinitely. There is no timeout, and the way out of a stuck bus is reset
— I2C's own position being that a target holding SCL is a target that is going to
let go. SMBus disagrees and specifies 35 ms; that would be another counter and
another `I2cReply`.

### What it does not do

One master, so no arbitration and no bus-busy check — multi-master I2C means
watching SDA for another master pulling it low under you, which is a second thing
to do with the SDA this already reads. `addressFor` is seven-bit addressing only;
ten-bit addressing and the general call are two `Write`s and a byte pipe does not
need to know the difference.

### How it is checked

`make test` runs it, in about a second, with no HDL simulator. The interesting part
is that the checks do not look at the master's outputs — they decode the two wires:

| What | Why |
| --- | --- |
| `decode` | Reads a `(SCL, SDA)` trace back as a list of START, STOP and bit, one event per stretch of SCL being high. So the expected value of a check *is* the waveform, and a data bit that moved while SCL was high comes back as a stray START rather than being quietly tidied up |
| `i2cBus` | The master, a pull-up on each line, and whatever else is pulling them down |
| `FakeTmp2` | A pretend temperature sensor, which is the section below |
| `stretcher` | Grabs SCL the first time it sees the line low and holds it down for a hundred cycles, which lands on the master's first data bit. The check is that the wire is *identical* to the unstretched one and the high periods are untouched — plus that one low period really did get much longer, without which a master that ignored SCL entirely would pass |

## A sensor that isn't there

`FakeSdCard` is what makes an SD design testable with an empty socket. `FakeTmp2`
is the same idea on the other bus: enough of an Analog Devices ADT7420 — the part
on a Digilent Pmod TMP2 — to be a real I2C target, watching the two wires and
moving SDA on the edges a chip moves it on. Both sit in `spec/` beside the checks
that use them, for the reason any fixture does: a double of a part is test code,
and a library that ships one is shipping a fixture. Being synthesisable Clash does
not change that. The price is that they are this suite's alone — a design's suite
is another package and cannot import them — so a driver of your own needs a double
of your own, and `spec/FakeTmp2.hs` is what one looks like.

A sensor is a better fake than a loopback because the interesting parts of I2C are
all about *which* device is talking:

```haskell
[ Start, Write (addressFor tmp2Address False), Write 0x00     -- point at the temperature
, Start, Write (addressFor tmp2Address True)                  -- turn the bus around
, Read True, Read False, Stop ]                               -- and take both halves
```

- **It answers to one address.** Ask for `0x48` instead and it says nothing at all,
  which is indistinguishable from an empty header — the check that says its address
  matching is real rather than a fake that acknowledges whatever it hears.
- **It has an address pointer,** written as the first byte of a write, and it
  survives a STOP. That is what makes "write the pointer, let go of the bus, come
  back and read" work, and most drivers are written that way rather than with a
  repeated START.
- **The pointer steps on for every byte read,** so a two-byte read is the high and
  low halves of one 16-bit register rather than the same byte twice. Reading three
  bytes from `0x00` walks into the status register, which the tests do.
- **It watches the master's acknowledge.** A NACK stops it talking, which matters
  more than it sounds: a target that kept going would hold SDA down across the STOP
  and wedge the bus it was being polite on.

The temperature itself is a `Signal`, in sixteenths of a degree, which is exactly
the part's resolution in its default 13-bit mode: the reading occupies the top
thirteen bits of the register pair and the bottom three are alarm flags against the
`T_HIGH`, `T_LOW` and `T_CRIT` setpoints. So `celsius 23 9` is 23.5625 °C, goes on
the wire as `0x0B 0xC8`, and `reading 0x0B 0xC8` gives it back — and at `celsius
(-3) (-4)` the bytes are `0xFE 0x61`, the `0x01` being the `T_LOW` flag that also
shows up in the status register. All four of those numbers are written out in
`spec/` rather than computed, so the encoding is stated somewhere other than in the
code that implements it.

What it is not is a part misbehaving. It converts instantly, is always ready, never
stretches the clock — the real one does not either — and its configuration register
is storage rather than a mode. 16-bit mode, the one-shot and SPS conversion modes,
the `INT` and `CT` pins, the hysteresis and fault queue, and the software reset are
all absent. The register map is a single `case`; add the one you need.

There is no `Pmod.Tmp2` driver to go with it. Writing one is a nice exercise and
the fake is what makes it a testable one — the transaction above is the whole of
what it has to do.

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
`constraints/Basys3-Uart.xdc`, opt-in for the reason every group file is, and
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
who owns the transmitter. The whole transmit side of `Io` is these two lines:

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
word most significant first, `dec` spells one in base ten, and `line` puts CR LF on
the end. A format is then a one-liner whose signature settles the digit count:

```haskell
word :: BitVector 16 -> Vec 6 (BitVector 8)
word = line . hex
```

Keeping those pure is what lets `stack test` check a format with a list comparison
instead of a trace — including a sweep of all 65536 values through `decDigits`,
which is the one function here where being right is not obvious by inspection.

`dec` is the `print 42` that prints `42`, and it is the only thing in this library
with a price worth knowing before you use it. Base sixteen is free: `hex` is a
`bitCoerce`, because four bits *are* a hex digit. Base ten is not, and an FPGA has no
divider to borrow, so `decDigits` is double dabble — one step per input bit, each
step doubling the decimal digits and carrying anything past nine into the next.
That is combinational and sixteen levels deep, which is why *how* the step is
written decides whether the design runs:

| One step written as | Depth | `sketch` at 100 MHz |
| --- | --- | --- |
| `if d >= 5 then d + 3 else d`, and a shift | a 4-bit adder, so a CARRY4 chain | 25 ns — **40 MHz, FAIL** |
| a 32-entry table, 5 bits in and 5 bits out | one LUT | ~8 ns — **125 MHz, PASS** |

Both are the same arithmetic; the second has it evaluated at compile time instead of
sixteen times in silicon, and a five-input table is exactly what one LUT6 does.
Sixteen LUTs fit in a 10 ns clock and sixteen carry chains do not. So it fits, and it
does not fit twice: something much wider wants the conversion registered partway, and
a design spelling two numbers wants to read the timing report before believing it is
fine. Numbers measured on this board, both times, and the fix was not a register —
the depth is in the logic, so a register moves it rather than shortening it.

The digit count is the caller's, because nothing in a `BitVector 16` says whether
five digits or four are wanted. Too few loses the most significant ones the way a
narrowing `resize` does. Leading zeros go out as spaces, right aligned, and zero is
still one digit. There is no decimal equivalent on the seven-segment display for the
same reason: four digits cannot show 65535, and silently dropping the digit that says
so is not a choice a library should make for you.

### Reading what the host typed

The other half of `serial`'s output is what came back, and a design almost never
wants the `UartRx` itself — it wants "did the host ask for something I understand?".
That is `decoded`, which takes the meaning of one byte and gives the meaning of the
stream:

```haskell
typed = decoded typedAs heard          -- Signal Basys3 (Maybe Typed)
```

`typedAs :: BitVector 8 -> Maybe Typed` is the design's own vocabulary — `k` and `j`
step the counter, `0`–`f` shift a digit in, everything else means nothing. The two
ways of getting `Nothing` collapse on purpose: no byte this cycle and a byte this
design ignores are the same non-event to whatever reads the result, and a terminal
sends far more of the second kind than of the first. A command that does not fit in
one byte needs its own state machine, which is a different thing and not this
function's job.

The error line wants the other helper. `rxError` is one cycle wide, so displaying it
straight puts ten nanoseconds of light on an LED; `latch` (in `src/Latch.hs`, all one
flip-flop of it) holds it until the domain is reset:

```haskell
faulty = latch (rxError <$> heard)
```

Both demos use exactly that line, and `Sd` uses the same function for `Failed`,
which `Pmod.SdCard` also passes through briefly on its way to another attempt. It is
a flip-flop and not a level-sensitive latch, despite the name — nothing here asks the
synthesiser to infer one of those.

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
| `src/Serial.hs` | The front door: `serial`, `Source`, `say`, `report`, `before`, and `decoded` for what came back |
| `src/Ascii.hs` | Pure text: `ascii`, `hex`, `dec`, `decDigits`, `hexChar`, `hexNibble`, `line` |
| `src/Latch.hs` | `latch`, for the one-cycle `rxError` |
| `src/Basys3.hs` | `baud115200`, the divisor for this board's clock, and `host`, which is `serial` with it applied |
| `examples/src/Sketch.hs` | The two-client shape at its smallest: a greeting, then the switches in decimal for ever after |
| `examples/src/Io.hs` | The greeting, `word` for how this design spells its counter, and `typedAs` for what the host may ask |
| `constraints/Basys3-Uart.xdc` | B18 and A18, and their timing exceptions |

`make sim` does not cover this: only `blinky` has a `TestBench` annotation. The
tests close the loop in Haskell instead, and the two suites split it where the
package boundary is. `spec/` wires the library to itself: the transmitter's line
into the receiver with frames back to back, hand-built frames into the receiver for
the glitch and framing-error cases, and each `Source` driving a real transmitter
into a real receiver, so what is compared is what a terminal would see.
`examples/test/` then drives the whole design from hand-built frames and decodes its
own transmit pin back — which is how "type `beef` and the display fills up from the
right" is a check rather than a claim.

## Layout

Two Stack packages, and the split is the point:

- **`basys3`** (this directory, `src/`) — the reusable half, and what the repository
  is named after. It knows nothing about any particular design, and it has its own
  test suite (`spec/`): `stack test basys3` answers "does the library still work?"
  without a design in scope, which is the question after moving the snapshot pin.
- **`basys3-examples`** (`examples/`) — the designs, one module each and the only
  place a `topEntity` lives, plus the Clash driver that compiles them and the suite
  that exercises them. All three need a design in scope, which is why they share a
  package.

The dependency runs one way, and it is the package graph that says so rather than a
convention: `import Io` inside `src/` does not resolve, because `basys3` does
not depend on `basys3-examples`. `clash-common.yaml` holds the extensions,
plugins and unfoldings both packages' hardware components need, included into each
with `<<: !include` so the two cannot drift apart. One of those extensions is not
from Clash's own template: `FlexibleContexts`, which every design naming this board
needs, because `HiddenClockResetEnable Basys3` constrains a concrete type rather than
a variable. Without it there, the recommended shape of a design fails to compile
until its author adds a pragma about an extension they had no reason to have heard
of — which is the kind of boilerplate `src/Basys3.hs` exists to remove.

The one thing to know about this shape: the `clash` and `clashi` executables live in
`examples/bin/`, not at the top level, because the Clash compiler resolves the
module it is handed — `Io`, `Sd` — through its own package environment. An
executable in `basys3` could not see one. Splitting the designs into an *internal*
library was tried first and does not work at all: cabal registers one as a hidden
package, and the GHC session inside `clash` cannot load a module out of it.

| Path | Purpose |
| --- | --- |
| `src/Ascii.hs` | Text as bytes, all of it pure: a string literal as a `Vec`, hex and decimal digits, a line ending |
| `src/Basys3.hs` | This board: clock domain, `onBoard`, prescaler, pin types and names, its timings, and the circuits with those timings applied |
| `src/Basys3/Board.hs` | That plus `Ascii`, `Serial`, both peripherals and `Clash.Prelude`, re-exported — the one import a design needs |
| `src/Latch.hs` | One flip-flop: `latch`, which remembers a one-cycle event for as long as anyone needs to see it |
| `src/Peripheral/SevenSegment.hs` | Digit decoder, scanning driver, word-to-digits |
| `src/Peripheral/Button.hs` | Synchroniser, debouncer, edge pulses — for any contact |
| `src/Pmod/SdCard.hs` | The Pmod SD: SD initialisation, a single-block read, and the six net names its constraints use |
| `src/Protocol/I2C.hs` | Single-master I2C: one START, STOP, byte or acknowledge at a time, and it honours a stretched clock |
| `src/Protocol/SPI.hs` | Byte-oriented SPI mode-0 master, independent of what is on the other end |
| `src/Protocol/UART.hs` | 8N1 transmitter and receiver, bit period as an argument |
| `src/Serial.hs` | The host link as one thing you talk to: `serial`, and the `Source`s that feed it |
| `examples/src/Blinky.hs` | The blinker: the LED pattern, `topEntity`, `testBench` |
| `examples/src/Io.hs` | The switch-and-button demo: switches on the LEDs, buttons on a counter, that counter on the serial link |
| `examples/src/Sd.hs` | The SD design's board wrapper: pins, LEDs, display |
| `examples/src/Sketch.hs` | The smallest complete design, and the template for the next one |
| `examples/design/*.mk` | One file per design: its module, its entity name, its constraint files. Adding one is how a design is added |
| `package.yaml`, `examples/package.yaml` | The two package descriptions, and the source of truth: Stack runs hpack on each, which generates the `.cabal` file beside it |
| `clash-common.yaml` | The hardware stanza both packages include: extensions, the three type-level plugins, unfoldings |
| `stack.yaml` | The snapshot — and therefore the Clash and GHC versions — and the list of packages |
| `spec/Spec.hs` | The library's own suite: the board's cycle counts, the UART both ways, debouncing, base ten, the SD controller against the pretend card, the I2C master against a decoded waveform and a pretend sensor |
| `spec/FakeSdCard.hs` | A pretend card: a real SPI slave that answers like one, so the controller is testable with an empty socket. Test code, hence here and not in the library |
| `spec/FakeTmp2.hs` | A pretend temperature sensor: an ADT7420 as a real I2C target, address matching and register pointer included. Test code, likewise |
| `examples/test/Spec.hs` | The designs' suite: what each one puts on its pins and on the wire |
| `constraints/Basys3.xdc` | The clock and the reset — the two ports every design has — and the index of the files below |
| `constraints/Basys3-Leds.xdc` | `led[15:0]`; opt-in, like every group file |
| `constraints/Basys3-Display.xdc` | `seg[6:0]`, `dp`, `an[3:0]` |
| `constraints/Basys3-Switches.xdc` | `sw[15:0]`, and their timing exception |
| `constraints/Basys3-Buttons.xdc` | `btnU`, `btnD`, `btnL`, `btnR`; btnC is the reset |
| `constraints/Basys3-Uart.xdc` | The two USB-UART pins |
| `constraints/Basys3-Vga.xdc` | The VGA connector; reference only, no design drives it |
| `constraints/Basys3-Ps2.xdc` | The USB HID port's PS/2 pair; reference only |
| `constraints/Basys3-Flash.xdc` | The configuration flash; reference only, and read its header first |
| `constraints/PmodSD.xdc` | The Pmod SD's timing exceptions and pinout notes, whichever header it is on |
| `constraints/PmodSD-J{A,B,C}.xdc` | The six pins, one file per header; `PMOD` picks one |
| `syn/openxc7.Containerfile` | Native arm64 image with yosys, nextpnr-xilinx and prjxray |
| `syn/openxc7.mk` | The bitstream flow, run inside that image |
| `test/dump.v` | `$dumpvars` root module, compiled in so `make sim` writes a VCD |
| `test/verilator.vlt` | One documented lint waiver, over all generated top entities, for Clash's 64-bit vector indices |
| `test/surfer-commands.txt` | Signals Surfer preselects when opening the generated test bench's waveform |
| `examples/bin/Clash.hs`, `examples/bin/Clashi.hs` | Entry points so `stack run clash` / `clashi` can see the designs |

Three directories have tests in them, and each answers a different question:

- `spec/` — the library's own suite, run by `stack test basys3`. Does a UART frame
  still come back as the byte that went in? Is `settle` still five milliseconds of
  this board's clock? Nothing in it names a design, so it goes on passing while the
  designs are being rewritten, and the checks double as the usage examples for
  anyone reading the library rather than these demos. The two pretend parts,
  `FakeSdCard` and `FakeTmp2`, are here too — a double of a chip is a fixture, and a
  library that ships one is shipping test code.
- `examples/test/` — the designs' suite, run by `stack test basys3-examples`. Does
  one press of btnU move the counter by exactly one? Does the board greet the host
  and then report the counter it was told? Every check here needs a design in scope.
  Nothing here drives `sd`: that needs the pretend card, which is in `spec/` and so
  in another package. What `sd` puts on its LEDs and display is unchecked; the
  controller under it is `spec/`'s business.
- `test/` — no Haskell at all. Fixtures for Verilator and Icarus, which read Verilog:
  the `$dumpvars` module `make sim` compiles in, the one lint waiver, and the signal
  list Surfer opens with.

`check`, and a frame-builder and a report-speller with it, are the same few lines in
both Haskell suites. Copied rather than shared: a fixture that crosses a package
boundary has to be exported by one of the two, and a library exporting its test
harness to keep its own tests tidy is a worse trade than thirty duplicated lines.

### Design notes

`blinky` takes its period as an argument rather than hard-coding it. `topEntity`
applies the real value — `99_999_999`, a pulse every 100e6 cycles = 1 s at
100 MHz, each pulse inverting all 16 LEDs — while both test benches use 2, so
twelve simulated cycles cover two blinks. `rotator`, the one-hot walking pattern,
is kept as an alternative and still covered by `stack test`; swap it in for the
blink to get a chase.

`Io` is the same shape with three such arguments, and one of them is called `hold`
and not `dwell`, which is the board's name for the same number: `dwell` is in scope
from `Basys3.Board`, and a parameter that shadows the constant it exists to replace
is confusing before it is a `-Wname-shadowing` warning. `Sketch` is the other half
of that comparison — the same display and the same link, written with `showHex` and
`host` and no numbers at all, and not simulable as a result.

The display is common anode with transistor drivers, so `seg` (CA…CG), `dp` and
`an` (the digit enables) are all **active low**, and only one digit is lit at a
time: `display` walks the four anodes, putting the matching digit's cathode
pattern out with it. `an[0]` is the rightmost digit. The three pins travel
together as `Basys3.Display`, a record, because `(BitVector 7, BitVector 4, Bit)`
is three ways round that all typecheck and only one of them lights the board.

Port names in the generated Verilog come from the `Synthesize` annotation on
`topEntity` and must match the XDC: `clk`, `rst`, `led[15:0]`, `seg[6:0]`,
`an[3:0]`, `dp`. No design spells them out. `Basys3` exports a `PortName` per pin
and `basys3`, which assembles the annotation — GHC's stage restriction means an
annotation may only mention imported names, so a library can hand a design its
port list where the design itself could not even factor one out:

```haskell
topEntity :: Clock Basys3 -> Reset Basys3 -> Signal Basys3 Leds
topEntity clk rst = onBoard clk rst (blinky 99_999_999)
{-# ANN topEntity (basys3 "blinky" [] ledsPort) #-}
```

`ledsPort` bare, because this design's output is one signal and not a tuple.
`ports` is for the tuple case: it is `PortProduct ""`, which names the fields
without prefixing them, so `Sketch`'s three outputs come out as `led`,
`seg`/`an`/`dp` and `uart_tx` rather than as numbered subfields of one product.

The `Basys3` domain declares an **active-high asynchronous** reset, matching
btnC, which reads high when pressed. Being a button, it bounces, and a reset that
bounces restarts the domain several times per press — visibly, on the serial link,
as a truncated frame per restart. `onBoard` is the wrapper above: the clock, the
enable line tied high, and btnC through Clash's `resetGlitchFilter` at the same
5 ms every other contact on the board waits. It has to be that rather than
`Peripheral.Button.debounce`, whose registers would be held at their initial state
by the very reset they are meant to release. The domain's `vPeriod` is also where
the clock period lives: Clash emits it as `blinky.sdc` next to the generated HDL,
so `constraints/Basys3.xdc` only assigns the W5 pin and never repeats the 10 ns.

Pin assignments were taken from Digilent's
[Basys3_Master.xdc](https://github.com/Digilent/digilent-xdc) and cross-checked
against it. What no design here drives yet is the VGA connector, the USB-HID port's
PS/2 pair, and the configuration flash; each has a file of its own —
`constraints/Basys3-Vga.xdc`, `-Ps2.xdc`, `-Flash.xdc` — with the pins already
cross-checked, so the work left is the Haskell side. Those three have never been
through place-and-route, since no top entity has the ports, so the port names in
them are a proposal for the first design that wants them to settle, together with
the matching `PortName` values in `src/Basys3.hs`. Each file's header says what
else that hardware needs: a pixel clock domain for VGA, bidirectional pins for
talking back to a keyboard, and for the flash the fact that its clock is not a
user I/O at all and that these are the nets the FPGA configures itself from.
