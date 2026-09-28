{-|
One import for a design on the Basys3. Everything in "Basys3", everything the
board is built out of, and Clash's own prelude:

@
{-\# LANGUAGE NoImplicitPrelude \#-}
module Mirror (topEntity) where

import Basys3.Board

mirror :: HiddenClockResetEnable Basys3 => Signal Basys3 Switches -> Signal Basys3 (Leds, Display)
mirror sw = bundle (leds, showHex leds)
 where leds = switches sw

topEntity :: Clock Basys3 -> Reset Basys3 -> Signal Basys3 Switches -> Signal Basys3 (Leds, Display)
topEntity = \\clk rst sw -> onBoard clk rst (mirror sw)
{-\# ANN topEntity (basys3 "mirror" [switchesPort] (ports [ledsPort, displayPort])) \#-}
@

That is the whole of a working design, and the reason this module exists: the
alternative is six imports with hand-maintained name lists, which is the first
boilerplate a beginner meets and the last one they would have thought to
anticipate. Nothing here is new -- it is "Basys3", "Ascii", "Serial", "Latch",
"Peripheral.Button", "Peripheral.SevenSegment" and "Clash.Prelude", re-exported
whole.

What each part is for:

  * "Basys3" is the board -- its domain, its pins, its timings, and the circuits
    with those timings already applied: 'switches', 'button', 'showHex', 'host'.
    Start here.
  * "Ascii" spells bytes: 'hex' and 'dec' for numbers, @$('ascii' "...")@ for
    literals, 'line' for the end of one.
  * "Serial" is what a design says to the host and hears back. 'Basys3.host' is
    'Serial.serial' with the baud rate in it, but the 'Serial.Source' handed to
    it comes from here: 'say', 'report', 'before', and 'decoded' for the other
    direction.
  * "Latch" is one flip-flop: 'latch' remembers a one-cycle event, which is what
    makes a fault visible on a lamp.
  * "Peripheral.Button" and "Peripheral.SevenSegment" are the untimed circuits
    underneath 'switches', 'button' and 'showHex'. A design that wants to be
    simulated in a few hundred cycles reaches past the board for these and takes
    its own timings as arguments -- which is what "Io" does.
  * "Clash.Prelude" replaces the standard one, since @clash-common.yaml@ turns
    @ImplicitPrelude@ off for every module in the project.

The one cost of importing it all at once is that plain words are taken: 'dwell',
'settle', 'switches', 'button', 'pressed', 'host', 'report', 'line', 'latch'. A
local binding may of course shadow one, but @-Wall@ will say so, and the warning is
usually right -- a circuit that takes its own settle time as an argument is doing
that so as /not/ to use the board's, and calling the argument @settle@ hides the
distinction the design was built around. The demos here use @hold@, @press@ and
@diagnostic@ where they would otherwise have shadowed.

The @Pmod@ modules are deliberately not here. A Pmod is something you bought
separately and plugged in, so a design that uses one says so in an import, and a
design that does not should not have "Pmod.SdCard"'s names in scope -- see the
"Sd" design, which imports this module and that one.
-}
module Basys3.Board
  ( module Basys3
  , module Ascii
  , module Serial
  , module Latch
  , module Peripheral.Button
  , module Peripheral.SevenSegment
  , module Clash.Prelude
  ) where

import Clash.Prelude

import Ascii
import Basys3
import Latch
import Peripheral.Button
import Peripheral.SevenSegment
import Serial
