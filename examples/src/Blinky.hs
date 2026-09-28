{-|
All 16 of the Basys3's LEDs blinking together, one second on and one second off,
with the four-digit display counting the blink cycles: 0001, 0002, … 9999, 0000.

The design is deliberately split into parameterised circuits ('blinky') and a
thin synthesis wrapper ('topEntity'): the wrapper hard-codes the real 100 MHz
timing, while simulation and the test bench instantiate the same circuits with
tiny periods so a handful of cycles is enough to see them work. That split is
the main reason to reach for Clash instead of writing the dividers out by hand
in Verilog.

The clock domain and the prescaler live in "Basys3" and the display driver in
"Peripheral.SevenSegment", since 'SdDemo' needs them too; they are re-exported
here for convenience.
-}
module Blinky
  ( Basys3
  , vBasys3
  , Digits
  , prescaler
  , blinkState
  , rotator
  , bcdSucc
  , sevenSeg
  , display
  , blinky
  , topEntity
  , testBench
  ) where

import Clash.Prelude
-- The test bench primitives take clock and reset explicitly, so they live in
-- Clash.Explicit.Testbench rather than being re-exported by Clash.Prelude.
import Clash.Explicit.Testbench (outputVerifier', tbSystemClockGen)

import Basys3                   (Basys3, Digits, Settle, prescaler, vBasys3)
import Peripheral.SevenSegment  (display, sevenSeg)

-- | The blink phase: flips on every enable pulse, starting dark.
blinkState :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom Bool
blinkState en = lit
 where
  lit = regEn False en (not <$> lit)

-- | A single lit LED that rotates one position left per enable pulse. Not part
-- of 'blinky' any more; kept as an alternative LED pattern.
rotator :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom (BitVector 16)
rotator en = leds
 where
  leds = regEn 1 en (flip rotateL 1 <$> leds)

-- | Increment a four-digit BCD number, wrapping 9999 back to 0000. The carry
-- ripples up from the least significant digit, which is why 'Digits' is
-- ordered that way. Counting in BCD avoids dividing by ten to get the digits.
bcdSucc :: Digits -> Digits
bcdSucc = snd . mapAccumL step True
 where
  step carry d
    | not carry = (False, d)
    | d == 9    = (True,  0)
    | otherwise = (False, d + 1)

-- | The whole design: all 16 LEDs blink together, and the display counts blink
-- cycles modulo 10000. Both periods are parameters so tests can pick tiny ones.
blinky
  :: HiddenClockResetEnable dom
  => Unsigned 32  -- ^ cycles - 1 between LED toggles
  -> Unsigned 32  -- ^ cycles - 1 that each digit is held lit
  -> Signal dom (BitVector 16, BitVector 7, BitVector 4, Bit)
blinky blinkLimit dwell = bundle (leds, seg, anode, pure high)
 where
  tick = prescaler blinkLimit
  lit  = blinkState tick
  leds = mux lit (pure maxBound) (pure 0)

  -- A cycle is dark-then-lit, so count on the transition into lit: the display
  -- steps to 0001 exactly as the LEDs first come on.
  cycled = tick .&&. (not <$> lit)
  digits = regEn (repeat 0) cycled (bcdSucc <$> digits)

  (seg, anode) = display (prescaler dwell) digits

-- | 100e6 cycles between toggles is one second at 100 MHz: one second on, one
-- second off, and one count per two seconds. Each digit is held for 100e3
-- cycles (1 ms), so the display refreshes at 250 Hz. The enable line is tied
-- high.
--
-- btnC arrives through 'resetGlitchFilter', which is 'Basys3.settle' for the one
-- contact that cannot go through "Peripheral.Button": the reset has to read
-- steady for 'Settle' cycles before the domain moves, so a bouncing press or
-- release is one reset rather than several restarts. Only the wrapper does this
-- -- 'testBench' drives 'blinky' directly, so nothing it verifies has to wait
-- 5 ms for reset to be believed.
topEntity
  :: Clock Basys3
  -> Reset Basys3
  -> Signal Basys3 (BitVector 16, BitVector 7, BitVector 4, Bit)
topEntity clk rst =
  withClockResetEnable clk (resetGlitchFilter (SNat @Settle) clk rst) enableGen
    (blinky 99_999_999 99_999)
{-# NOINLINE topEntity #-}
{-# ANN topEntity
  (Synthesize
    { t_name   = "blinky"
    , t_inputs = [PortName "clk", PortName "rst"]
    , t_output = PortProduct ""
                   [ PortName "led"
                   , PortName "seg"
                   , PortName "an"
                   , PortName "dp"
                   ]
    }) #-}

-- | HDL test bench: generated alongside the design and run in Icarus Verilog by
-- @make sim@. A blink limit of 2 makes each half of the blink three cycles
-- long, and a dwell of 100 parks the scan on digit 0 (@an = 1110@) for the whole
-- run, so the display shows the ones digit stepping 0, 1, 2.
testBench :: Signal System Bool
testBench = done
 where
  expectedOutput = outputVerifier' clk rst expected
  expected =
    concat
      (  replicate d3 (0x0000, 0x40, 0xE, high)  -- dark, "0"
      :> replicate d3 (0xFFFF, 0x79, 0xE, high)  -- lit,  "1"
      :> replicate d3 (0x0000, 0x79, 0xE, high)  -- dark, "1"
      :> replicate d3 (0xFFFF, 0x24, 0xE, high)  -- lit,  "2"
      :> Nil )
  done = expectedOutput (withClockResetEnable clk rst enableGen (blinky 2 100))
  clk  = tbSystemClockGen (not <$> done)
  rst  = systemResetGen
{-# ANN testBench (TestBench 'topEntity) #-}
