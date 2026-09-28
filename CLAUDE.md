# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Clash (Haskell → HDL) library of the Digilent Basys3's own hardware — display
multiplexing, button debouncing, a UART, base ten and sixteen, SD over SPI, plus the
board's pin names and clock period — with four example designs that use it. Closer
to an Arduino library than a demo. The whole toolchain runs natively on Apple
Silicon, place-and-route included; no vendor tools.

Board: Artix-7 `xc7a35tcpg236-1`, 100 MHz clock on W5, 16 LEDs, four-digit
seven-segment display, FT2232HQ that is both USB-JTAG and a USB-serial bridge.

## Commands

```bash
make                  # list targets
make designs          # list designs and what each does
make build            # stack build --test --no-run-tests (type-checks both suites)
make test             # both Haskell test suites; seconds, no HDL simulator
make repl             # clashi on examples/src/$(TOP_MODULE).hs
make verilog          # Clash -> verilog/<Module>.topEntity/
make sim              # generated HDL test bench in Icarus Verilog (blinky only)
make waves            # sim, then Surfer on sim/testBench.vcd
make lint             # Verilator lint over the generated Verilog
make openxc7-image    # one-off, slow: build the synthesis container image
make bitstream        # yosys + nextpnr-xilinx + prjxray inside that image
make flash            # into SRAM;  make flash-persist writes QSPI
make monitor          # serial terminal on the board's UART, 115200
```

`DESIGN=` applies to every target except `make test` (always runs everything) and
`make monitor`. Designs are `blinky` (default), `sketch`, `io`, `sd`. `PMOD=JA|JB|JC`
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
work with no design in scope. `examples/test/` — do the designs wire the library's
parts up the way their haddock says. `test/` — HDL fixtures for Verilator and
Icarus (`dump.v`, `verilator.vlt`, `surfer-commands.txt`), no Haskell. `check`,
`frame` and `said` are deliberately duplicated between the two Haskell suites: a
library should not export its test harness to keep its own tests tidy.

## Library namespaces

| Namespace | Contains | Knows about |
| --- | --- | --- |
| `Protocol.*` | `SPI`, `UART` — how to talk on a wire | Timing and framing, not devices |
| `Peripheral.*` | `SevenSegment`, `Button` | Devices, not boards — **every timing is an argument** |
| `Pmod.*` | `SdCard`, `FakeSdCard` — one module per plug-in board | Its own protocol, not which header |
| `Basys3` | This board: clock domain, pin widths, the cycle counts that make the above concrete | Everything, nothing reusable |
| `Ascii`, `Serial`, `Latch` | Unprefixed on purpose: text, the host link, one register | Not a wire, a device class, or a Pmod |

`Basys3.Board` is the single-import façade: the board, the peripherals, the text and
Clash's prelude re-exported together. A design imports that and nothing else —
except `Pmod.*`, deliberately excluded so a design that uses an add-on says so.

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
  `Pmod.FakeSdCard`.
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
