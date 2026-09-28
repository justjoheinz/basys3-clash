{-|
All 16 of the Basys3's LEDs blinking together, one second on and one second off,
and nothing else. It is the smallest thing this board can be asked to do that is
still visible from across the room.

The design is deliberately split into a parameterised circuit ('blinky') and a
thin synthesis wrapper ('topEntity'): the wrapper hard-codes the real 100 MHz
timing, while simulation and the test bench instantiate the same circuit with a
tiny period so a handful of cycles is enough to see it work. That split is the
main reason to reach for Clash instead of writing the divider out by hand in
Verilog.

The board and Clash's prelude both arrive in the single "Basys3.Board" import;
'Sketch' is the smallest design that does something with an input.
-}
module Blinky
  ( blinkState
  , rotator
  , blinky
  , topEntity
  , testBench
  ) where

import Basys3.Board
-- The test bench primitives take clock and reset explicitly, so they live in
-- Clash.Explicit.Testbench rather than being re-exported by Clash.Prelude -- and
-- so not by "Basys3.Board" either.
import Clash.Explicit.Testbench (outputVerifier', tbSystemClockGen)

-- | The blink phase: flips on every enable pulse, starting dark.
blinkState :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom Bool
blinkState en = lit
 where
  lit = regEn False en (not <$> lit)

-- | A single lit LED that rotates one position left per enable pulse. Not part
-- of 'blinky'; kept as an alternative LED pattern.
rotator :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom (BitVector 16)
rotator en = leds
 where
  leds = regEn 1 en (flip rotateL 1 <$> leds)

-- | The whole design: all 16 LEDs blink together. The period is a parameter so
-- tests can pick a tiny one.
blinky
  :: HiddenClockResetEnable dom
  => Unsigned 32  -- ^ cycles - 1 between LED toggles
  -> Signal dom Leds
blinky blinkLimit = mux lit (pure maxBound) (pure 0)
 where
  -- Named rather than inlined so both appear in the waveform under those names:
  -- @test\/surfer-commands.txt@ preselects them.
  tick = prescaler blinkLimit
  lit  = blinkState tick

-- | 100e6 cycles between toggles is one second at 100 MHz: one second on, one
-- second off. The enable line is tied high.
--
-- 'Basys3.onBoard' is the clock, the enable line and btnC debounced as the reset:
-- the domain does not move until the button has read steady for 'Basys3.Settle'
-- cycles, so a bouncing press is one reset rather than several restarts. Only the
-- wrapper does this -- 'testBench' drives 'blinky' directly, so nothing it
-- verifies has to wait 5 ms for reset to be believed.
--
-- One output, and not a tuple, so the annotation names the port directly instead
-- of going through 'Basys3.ports'.
topEntity :: Clock Basys3 -> Reset Basys3 -> Signal Basys3 Leds
topEntity clk rst = onBoard clk rst (blinky 99_999_999)
{-# NOINLINE topEntity #-}
{-# ANN topEntity (basys3 "blinky" [] ledsPort) #-}

-- | HDL test bench: generated alongside the design and run in Icarus Verilog by
-- @make sim@. A blink limit of 2 makes each half of the blink three cycles long,
-- so twelve samples are two whole blinks.
testBench :: Signal System Bool
testBench = done
 where
  expectedOutput = outputVerifier' clk rst expected
  expected =
    concat
      (  replicate d3 0x0000  -- dark
      :> replicate d3 0xFFFF  -- lit
      :> replicate d3 0x0000
      :> replicate d3 0xFFFF
      :> Nil )
  done = expectedOutput (withClockResetEnable clk rst enableGen (blinky 2))
  clk  = tbSystemClockGen (not <$> done)
  rst  = systemResetGen
{-# ANN testBench (TestBench 'topEntity) #-}
