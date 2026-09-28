-- createDomain generates a KnownDomain instance, which GHC classes as an
-- orphan. That is the normal way to declare a clock domain in Clash.
{-# OPTIONS_GHC -Wno-orphans #-}

{-|
The board itself, as opposed to any one design on it: its clock domain, the
widths of the things bolted to its pins, and the cycle counts that turn the
general-purpose blocks under @Peripheral@ into circuits for /this/ board's
100 MHz clock.

The split is the same one 'Blinky' makes between its parameterised circuits and
its @topEntity@: everything here is concrete, everything it builds on takes the
timing as an argument so a test can pick a period it can afford to simulate.

  * "Peripheral.SevenSegment" drives the display; 'Digits' is this board's
    four-digit instance of it.
  * "Peripheral.Button" conditions the buttons and switches, at 'settle' cycles.
    btnC waits the same 'Settle' for its contact to stop bouncing, but through
    'resetGlitchFilter' in each @topEntity@, because it is the reset itself.
  * "Protocol.UART" talks to the host over the board's USB-serial bridge, at
    'baud115200' cycles per bit.

The board also has 16 LEDs and a decimal point, which need no logic at all --
'Leds' and the @dp@ port are just wires.
-}
module Basys3
  ( -- * The board
    Basys3
  , vBasys3
  , prescaler
    -- * What is wired to the pins
  , Digits
  , Leds
  , Switches
    -- * Conditioning its contacts
  , Settle
  , settle
    -- * Talking to the host
  , baud115200
  ) where

import Clash.Prelude

-- | The Basys3 has a single-ended 100 MHz oscillator on pin W5. We use the
-- centre push button (btnC, pin U18) as reset, which reads high when pressed,
-- hence 'ActiveHigh'.
createDomain vSystem{ vName          = "Basys3"
                    , vPeriod        = hzToPeriod 100e6
                    , vResetPolarity = ActiveHigh
                    }

-- | Pulses high for exactly one cycle every @limit + 1@ cycles.
prescaler :: HiddenClockResetEnable dom => Unsigned 32 -> Signal dom Bool
prescaler limit = tick
 where
  count = register 0 next
  next  = mux tick 0 (count + 1)
  tick  = (== limit) <$> count

-- | Four display digits, least significant first: index 0 is driven onto AN0,
-- which is the rightmost digit on the board.
type Digits = Vec 4 (Unsigned 4)

-- | The 16 LEDs in a row above the switches, bit 0 rightmost. Active high, and
-- nothing stands between the register and the pin.
type Leds = BitVector 16

-- | The 16 slide switches along the bottom edge, bit 0 rightmost. High when the
-- switch is up. Pass them through "Peripheral.Button"'s @bank settle@ before
-- using them.
type Switches = BitVector 16

-- | Cycles a contact must read steady before the board believes it: 5 ms at
-- 100 MHz. Tactile switches and slide switches of this kind bounce for a few
-- hundred microseconds, so this is roughly an order of magnitude clear of the
-- problem while staying far below the ~50 ms at which a button starts to feel
-- unresponsive.
--
-- At the type level because one of its two users can only have it that way:
-- 'resetGlitchFilter' takes an 'SNat', so btnC's five milliseconds cannot be a
-- value. Naming the number once and deriving 'settle' from it is what stops the
-- reset's idea of /settled/ drifting from every other contact's.
type Settle = 500_000

-- | 'Settle' as "Peripheral.Button" wants it, which is cycles minus one.
--
-- A number rather than a pre-applied circuit, for the reason 'Blinky.topEntity'
-- passes @99_999_999@ by hand: a design that hard-codes five milliseconds cannot
-- be simulated, so the timing belongs in each @topEntity@ where a test can
-- substitute something it can afford to run.
--
-- All five buttons read high when pressed, so the pin goes straight in. btnC is
-- not among them: it is the reset, and a debouncer for it cannot be built out of
-- 'Peripheral.Button.debounce', whose registers live in this domain and would be
-- held at their initial state by the very reset they are meant to release --
-- asserting reset, clearing the counter, releasing reset, counting again, which
-- is a 5 ms oscillator rather than a debounced button. 'resetGlitchFilter' is the
-- same wait built where that loop cannot close: it takes a bare 'Clock' and no
-- 'Reset', so nothing it contains can be held by its own output. Each
-- @topEntity@ wraps btnC in it at 'Settle'.
settle :: Unsigned 32
settle = snatToNum (SNat @Settle) - 1

-- | Clock cycles per UART bit, minus one, for 115200 baud: 100e6 \/ 115200 is
-- 868.06, so each bit is 868 cycles and the divisor "Protocol.UART" wants is 867.
-- That rounding puts the realised rate at 100e6 \/ 868 = 115207 baud, which is
-- 0.006% fast.
--
-- What that error has to beat: a receiver samples the stop bit nine and a half
-- bit periods after the start edge, so the two ends' rates may differ by just
-- under 5% before a sample lands in the wrong bit. Our 0.006% leaves effectively
-- the whole budget to the host's end of the cable.
--
-- A number rather than a pre-applied circuit, for the reason 'settle' is one.
-- 'Unsigned 16' bottoms out at 65535, which is 100e6 \/ 65536 = 1526 baud: every
-- standard rate from 2400 up fits, 1200 would not. Other rates are
-- @round (100e6 \/ baud) - 1@, so 9600 is 10416.
baud115200 :: Unsigned 16
baud115200 = 867
