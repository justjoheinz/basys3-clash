{-|
The smallest design worth flashing, and the one to copy when starting another:
the switches on the LEDs, their value on the display in hex and on the host in
decimal, and the decimal point as a lamp for a bad serial link.

  * Flip the switches. The LEDs follow them, the display shows the same 16 bits
    as four hex digits, and a line of decimal arrives in the terminal each time
    the value settles.
  * @make monitor DESIGN=sketch@ to watch it, at 115200 baud.
  * btnC is reset, which re-sends the greeting.

It is here to be read as much as run, because it is the whole of what this
library asks of a design:

  * __One import.__ "Basys3.Board" is the board, the peripherals, the text and
    Clash's prelude together.
  * __No numbers.__ Not a settle time, not a refresh rate, not a baud divisor.
    'switches', 'showHex' and 'host' are those numbers already applied, which is
    the difference between this file and "Io".
  * __Named ports.__ The annotation is built from the 'PortName' values the
    library exports, so the strings that have to match @constraints\/@ are not
    retyped here at all.

The cost of the second one is that this design cannot be simulated: 'Basys3.settle'
is 500,000 cycles and 'Basys3.dwell' 100,000, so watching the display scan round
once takes 400,000 clock ticks. "Io" is the same kind of design written the
other way -- its circuit takes those three timings as arguments, and its
@topEntity@ is the only place the board's real ones appear -- which is why
@make test@ can exercise it in a few hundred cycles. Both shapes are legitimate.
Reach for this one first, and for that one when the logic gets interesting enough
to be worth a test.
-}
module Sketch
  ( sketch
  , topEntity
  ) where

import Basys3.Board

-- | Switches to LEDs, display and host. Nothing in it is about this board except
-- the names it calls things by.
sketch
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Switches
  -> Signal Basys3 Bit
  -- ^ uart_rx, the line from the host.
  -> Signal Basys3 (Leds, Display, Bit)
sketch sw rxPin = bundle (leds, withPoint faulty (showHex leds), tx)
 where
  -- Debounced, because a slide switch bounces like any other contact, and the
  -- report below would otherwise spell out every bounce.
  leds = switches sw

  -- Two things talk: the greeting, once, and the switch value for ever after.
  -- 'before' is the whole of the arbitration.
  --
  -- @dec \@5@ because five digits is what 16 bits need -- 65535 -- and nothing in
  -- the value says so: see 'Ascii.dec'. The display gets hex instead because four
  -- digits is all it has.
  --
  -- This one line is also the whole of this design's critical path: base ten is the
  -- only thing here that is not wires and a counter, and place-and-route puts the
  -- design at 125 MHz because of it. 'Ascii.decDigits' says what that buys and what
  -- it would cost to ask for more digits.
  (tx, heard) = host rxPin
                  (say $(ascii "Flip a switch.\r\n") atReset
                     `before` report (line . dec @5) leds)

  -- A framing error is one cycle wide and means the terminal is set to the wrong
  -- speed, so 'latch' it. Nothing else here reads the host, but the pin is worth
  -- having for this alone: the alternative symptom is a silent link.
  faulty = latch (rxError <$> heard)

-- | This board's timings go in via 'onBoard', 'switches', 'showHex' and 'host',
-- which between them leave nothing for this function to say.
topEntity
  :: Clock Basys3
  -> Reset Basys3
  -> Signal Basys3 Switches
  -> Signal Basys3 Bit
  -> Signal Basys3 (Leds, Display, Bit)
topEntity clk rst sw rxPin = onBoard clk rst (sketch sw rxPin)
{-# NOINLINE topEntity #-}
{-# ANN topEntity
  (basys3 "sketch"
    [switchesPort, uartRxPort]
    (ports [ledsPort, displayPort, uartTxPort])) #-}
