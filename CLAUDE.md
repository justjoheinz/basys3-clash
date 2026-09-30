# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Clash (Haskell → HDL) library of the Digilent Basys3's own hardware — display
multiplexing, button debouncing, a UART, base ten and sixteen, SD over SPI, an I2C
master, VGA at 640x480 with a font ROM, plus the board's pin names and clock period
— with four example designs that use it. Closer to an Arduino library than a demo.
The whole toolchain runs natively on Apple Silicon, place-and-route included; no
vendor tools.

Board: Artix-7 `xc7a35tcpg236-1`, 100 MHz clock on W5, 16 LEDs, four-digit
seven-segment display, VGA connector, FT2232HQ that is both USB-JTAG and a
USB-serial bridge.

**No design uses the VGA half yet.** The library code is written and tested in
`spec/`, but nothing has VGA ports, so `make verilog`/`lint`/`bitstream` have never
touched it and it has never been on a monitor. Don't describe it as working
hardware.

## Commands

```bash
make                  # list targets
make designs          # list designs and what each does
make build            # stack build --test --no-run-tests (type-checks both suites)
make test             # both Haskell test suites; seconds, no HDL simulator
make repl             # clashi on examples/src/$(TOP_MODULE).hs
make font             # one-off, needs the network: regenerate src/Screen/Font/Unscii8.hs
make verilog          # Clash -> verilog/<Module>.topEntity/
make sim              # generated HDL test bench in Icarus Verilog (blinky only)
make waves            # sim, then Surfer on sim/testBench.vcd
make lint             # Verilator lint over the generated Verilog
make openxc7-image    # one-off, slow: build the synthesis container image
make bitstream        # yosys + nextpnr-xilinx + prjxray inside that image
make flash            # into SRAM;  make flash-persist writes QSPI
make monitor          # serial terminal on the board's UART, 115200
```

`DESIGN=` applies to every target except `make test` (always runs everything),
`make font` and `make monitor`. Designs are `blinky` (default), `sketch`, `io`, `sd`. `PMOD=JA|JB|JC`
picks the SD module's header and changes only the pin constraints.

Running one suite rather than both:

```bash
stack test basys3            # the library alone (spec/) -- what to run after bumping the snapshot
stack test basys3-examples   # the designs alone (examples/test/)
```

There is no way to run a single check. Both suites are plain `main :: IO ()`
programs with a hand-rolled `check` helper and no test framework, so there are no
filter flags. They take seconds; run the whole suite. To poke at one signal, use
`make repl` and sample it:

```haskell
sampleN @System 20 (withClockResetEnable clockGen resetGen enableGen (blinky 2))
```

## Two packages, and why

| Package | Where | Holds |
| --- | --- | --- |
| `basys3` | `.` — `src/`, suite in `spec/` | The reusable half. Cannot import a design. |
| `basys3-examples` | `examples/` — designs in `src/`, Clash drivers in `bin/`, suite in `test/` | Everything that knows a design exists. |

The dependency runs one way and the package graph enforces it: `import Io` inside
`src/` is a compile error rather than something a reviewer has to catch.

**Three test directories, three different questions.** `spec/` — does the library
work with no design in scope; also holds `FakeSdCard` and `FakeTmp2`, the two
pretend parts. `examples/test/` — do the designs wire the library's parts up the way
their haddock says. `test/` — HDL fixtures for Verilator and Icarus (`dump.v`,
`verilator.vlt`, `surfer-commands.txt`), no Haskell. `check`, `frame` and `said` are
deliberately duplicated between the two Haskell suites: a library should not export
its test harness to keep its own tests tidy.

**A fake belongs in a test directory, never in `src/`.** A double of a chip is a
fixture, whatever namespace it would fit: the library does not ship one. The
consequence is load-bearing and not a bug to fix — `spec/`'s fakes are invisible to
`examples/test/`, which is another package, so **the `sd` design has no check on what
it puts on its LEDs and display**. `spec/` covers the controller underneath it. A
design's suite that wants a fake needs its own copy, the same trade `check` makes.

## Library namespaces

| Namespace | Contains | Knows about |
| --- | --- | --- |
| `Protocol.*` | `SPI`, `UART`, `I2C`, `VGA` — how to talk on a wire | Timing and framing, not devices |
| `Peripheral.*` | `SevenSegment`, `Button` | Devices, not boards — **every timing is an argument** |
| `Pmod.*` | `SdCard` — one module per plug-in board. **No fakes here**: a double of a part is test code and lives in `spec/` | Its own protocol, not which header |
| `Basys3` | This board: clock domain, pin widths, the cycle counts that make the above concrete | Everything, nothing reusable |
| `Ascii`, `Serial`, `Screen`, `Latch` | Unprefixed on purpose: text, the host link, what is on the screen, one register | Not a wire, a device class, or a Pmod |

`Basys3.Board` is the single-import façade: the board, the peripherals, the text, the
screen and Clash's prelude re-exported together. A design imports that and nothing
else — except `Pmod.*`, deliberately excluded so a design that uses an add-on says
so, and `Screen.Font`, excluded for the same reason: a font is a block RAM a design
chose to spend.

`Screen` re-exports `Protocol.VGA`, so `Scan`/`scanAt` arrive with it; `Basys3.screen`
and `Basys3.vgaPins` are the board's end. `Screen.Font` is unscii 8x8 (Public Domain)
in a `MemBlob`, with `src/Screen/Font/Unscii8.hs` generated by `tools/unscii.py` and
checked in.

## Conventions that are load-bearing

**Circuits take their timings as arguments; only `topEntity` knows the real ones.**
`blinky 99_999_999` in the wrapper, `blinky 2` in a test, so twelve simulated cycles
cover two blinks instead of 200 million. `Sketch` is the deliberate counterexample —
it uses `switches`/`showHex`/`host`, which are those numbers already applied, and so
cannot be simulated at all. Both shapes are legitimate; reach for `Sketch`'s first.

A parameter that duplicates a board constant gets a different name (`hold`, not
`dwell`) because the constant is in scope via `Basys3.Board` and shadowing it is a
`-Wname-shadowing` warning before it is confusing.

**Port names come from the library, not from the design.** GHC's stage restriction
means an `ANN` expression may only mention imported names — which is exactly what
lets `Basys3` export a `PortName` per pin plus the `basys3` annotation builder, where
a design could not even factor its own port list out. `ports = PortProduct ""` keeps
tuple fields flat (`led`, `seg`/`an`/`dp`, `uart_tx`); a single non-tuple output uses
the bare `PortName`:

```haskell
{-# ANN topEntity (basys3 "blinky" [] ledsPort) #-}                         -- one output
{-# ANN topEntity (basys3 "sketch" [switchesPort, uartRxPort]
                     (ports [ledsPort, displayPort, uartTxPort])) #-}       -- a tuple
```

**Domain annotations go at simulation sites only.** `MonoLocalBinds` — implied by
`TypeFamilies` in `clash-common.yaml` — stops local `where` bindings generalising, so
they take their domain from their use site, feedback loops and tuple patterns
included. Annotate the `sampleN`/`clockGen` call, never a local binding. Size and
length annotations (`:: Saying n` in `Serial.hs`) *are* needed and are a different
thing. The symptom of a missing domain is `Ambiguous type variable ‘dom0’ arising
from a use of ‘sampleN’`.

**Base ten is the critical path.** `Ascii.decDigits` is double dabble, one LUT level
per input bit, ~8 ns for 16 bits. `Ascii.steps` is a 32-entry truth table
(`indicesI`, evaluated at compile time) and must stay one: written as the usual
`if d >= 5 then d + 3`, each step becomes a CARRY4 chain, measured at 25 ns — 40 MHz,
failing timing. A register does not help; the depth is in the logic.

**The VGA pixel rate is an enable, not a second clock domain.** `Basys3.dot = 3` and
`pixel = prescaler dot` give 25.000 MHz in the ordinary `Basys3` domain — 0.7% under
the mode's 25.175, so 59.52 Hz instead of 59.94, which monitors accept. A real
pixel-clock domain would need `create_clock` plus `set_clock_groups`, and
nextpnr-xilinx *silently ignores* constraints it doesn't implement, so the crossing
would look constrained and be unchecked. It also means every higher mode is out of
reach: none of their pixel clocks divides 100 MHz, and MMCMs aren't reliable in this
flow. Don't add modes that can't be clocked here.

Two consequences of the 4-cycle pixel worth keeping in mind: the pixel path has 40 ns
rather than 10, and up to **3 cycles of read latency on the colour path are free** —
a constant delay relative to the syncs is a sub-pixel horizontal shift. At 4 it
becomes a whole pixel and the address must lead the beam.

## Adding a design

Two new files, nothing to edit. `examples/src/Foo.hs` with a `topEntity` and a
`Synthesize` annotation (copy `Sketch.hs`), and `examples/design/foo.mk` naming the
module, the entity string its annotation chose, its `constraints/*.xdc` files and one
line of description. The Makefile lists that directory, and hpack globs
`examples/src`, so neither needs changing.

`TOP_ENTITY` is spelt out rather than lowercased from `TOP_MODULE`: the string in
`basys3 "sketch"` is the design's to choose, and deriving it would turn a rename into
a silent mismatch. Module names are capitalised, so `Io`/`Sd` are the modules and
`io`/`sd` the circuits, entity strings and `DESIGN=` names.

The `XDC` list is checked in one direction only — a port with no constraint fails
late, in nextpnr's FASM step, with "port X of type PAD has no IOSTANDARD property",
while a constraint for a port the design lacks is silently ignored.

## Packaging

`package.yaml`, `examples/package.yaml` and `clash-common.yaml` are the source of
truth; **never edit `basys3.cabal` or `examples/basys3-examples.cabal`** — both are
gitignored and regenerated by hpack on every build. No module lists appear anywhere:
hpack walks `source-dirs`, so a new module is a new file and nothing else. A new
*suite* needs a `tests:` stanza.

`clash-common.yaml` is merged into every component containing hardware code with
`<<: !include`, so the library and the designs cannot drift apart on extensions or
plugins. The plain merge key matters — `&anchor !include` makes hpack fail with
"Unknown alias". The `clash`/`clashi` executables deliberately exclude it: they are
ordinary Haskell.

`stack.yaml` pins `nightly-2026-09-24` (Clash 1.10.2, GHC 9.12.4) and needs no
`extra-deps`. Stack, not cabal.

## Gotchas worth knowing before they cost an hour

- **Renaming a package** leaves the old one registered in the project's package db,
  and the next build fails with `Ambiguous module name`. Either
  `stack exec -- ghc-pkg --package-db=<project pkgdb> unregister --force <old>`, or
  `make distclean`.
- **`vvp` exits 0 on a failed assertion.** Clash's `outputVerifier` prints and calls
  `$finish`, so `make sim` greps its own log for `expected:` and decides PASS/FAIL.
  Checked against a deliberately wrong expected value.
- **The `verilog` target has no `touch`, on purpose.** Clash leaves output whose
  inputs hash the same byte- and mtime-identical, so the target stays older than its
  sources and Clash re-runs every time (one second). The trade is that `bitstream`
  then sees an unchanged `.v` and skips place-and-route, instead of re-routing
  whenever a comment changes.
- **Close `make monitor` before `make flash`.** One USB connector, two FTDI channels;
  a `cu.*` terminal takes `TIOCEXCL` over the whole device and flashing dies with
  "unable to claim usb device". A `tty.*` opener (VS Code's Serial Monitor) does not
  block flashing but does block `cu.*`.
- **`make sim` and `make waves` only work for `blinky`** — it is the one design with a
  `TestBench` annotation. The SD controller is checked in `make test` instead, against
  `spec/FakeSdCard.hs`.
- **nextpnr's report over-counts block RAM.** Each design's `*.report.json` under
  `build/openxc7/` says
  `RAMB36E1: 0/75`, which is the `xc7a50t` die — prjxray's database doesn't mask the
  blocks fused off on the 35T. The part has **fifty** 36-Kb blocks, 1,800 Kb, per
  Xilinx DS180. Budget against that. (640x480 is 307,200 pixels: 1 bpp is 17% of it,
  4 bpp 67%, 8 bpp does not fit. There is no external RAM on this board.)
- `test/surfer-commands.txt` preselects signals by name (`tick`, `count`, `lit`), so
  inlining a named `where` binding in a design silently empties the waveform window.

## CI

`.github/workflows/` has three, and only the first runs by itself:

| Workflow | When | What |
| --- | --- | --- |
| `ci.yml` | every push, PRs to `main` | the library's suite first, then the designs', then `make sim` and `make lint` |
| `bitstream.yml` | **manual only** | place and route every design, `sd` on all three headers |
| `toolchain-image.yml` | **manual only** | builds the openXC7 image, pushes it to ghcr.io |

`ci.yml` is about the library: `stack build basys3` and `stack test basys3` are their
own steps, ahead of anything with a `topEntity`, so a library failure is not buried
under a design's. It needs no container — Stack plus apt's `iverilog` and `verilator`
is the whole toolchain, and the container appears in only three lines of the Makefile
(the `openxc7-image` and `$(BITSTREAM)` rules).

The other two are manual because pin constraints and timing closure are properties of
a design, not of the library. Run `bitstream.yml` by hand after touching a critical
path: `Ascii.decDigits` is library code, nextpnr gets no `--timing-allow-fail`, and a
depth regression is invisible to every other check here — `make test` and `make lint`
are both perfectly happy with logic too deep to clock. It pulls the image
`toolchain-image.yml` publishes, so **that has to have run at least once** first.

CI is amd64 and a Mac is arm64; the Containerfile pins no architecture, so each side
builds its own natively and the registry tag carries the arch (`:latest-amd64`,
`:latest-arm64`). Both workflows derive that suffix from `uname -m`, so switching a
job to `ubuntu-24.04-arm` needs no other edit.

Both Stack caches are shared between `ci.yml` and `bitstream.yml` by key. Bump the
`stack-work-v1-` prefix to discard the build-output cache — needed if a package is
ever renamed, or the restored cache reproduces the `Ambiguous module name` failure
above.

Verilator comes from apt and is behind the 5.052 that `test/verilator.vlt` was
written against. Both tool versions are echoed in the log, because a lint that fails
only in CI is version drift before it is a defect.

The README is long and is the real reference — design notes, the double-dabble
timing table, the serial protocol, SD bring-up, and measured place-and-route figures
per design.
