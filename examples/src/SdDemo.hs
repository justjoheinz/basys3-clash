{-|
Reading block zero of an SD card over SPI on a Pmod SD, and reporting what
happened on the Basys3's LEDs and display.

The interesting work is in "Protocol.SPI" and "Pmod.SdCard"; this is only the
board wrapper. What it adds is a way to see the result without a logic analyser:

  * The display normally shows the last two bytes of the block as four hex
    digits. A card with a partition table has @0x55AA@ there, so a working read
    of a formatted card ends with @55AA@ on the display.
  * If an attempt fails, the display switches to @F@, the stage that failed, and
    the status byte the card answered with -- which is the pair of facts worth
    having when it does not work. An empty socket reads @F1FF@: nothing answered
    CMD0.
  * The LEDs carry the same information continuously: stage, failed stage, the
    socket's two switches, and two summary bits.

'Pmod.SdCard' retries after a failure, so no button press is needed -- inserting a
card turns @F1FF@ into the card's data within a few milliseconds. btnC resets the
whole domain, which starts again from scratch and is how to re-read after a card
has been swapped.
-}
module SdDemo
  ( lights
  , sdDemo
  , topEntity
  ) where

import Clash.Prelude

import Basys3                  (Basys3, Leds, Settle, prescaler)
import Peripheral.SevenSegment (display, hexDigits)
import Pmod.SdCard             (SdOut (..), Stage (..), sdCard)

-- | What the LEDs show, most significant bit first:
--
-- > 15     ready
-- > 14     an attempt has failed
-- > 13..10 unused
-- > 9      write protect switch, as the pin reads
-- > 8      card detect switch, as the pin reads
-- > 7..4   the stage that gave up
-- > 3..0   the current stage
--
-- The stage codes are the 'Stage' constructor order: 0 is the power-on
-- clocking, 7 'Ready', 8 'Failed'. While the controller is retrying, the low
-- nibble flickers through the stages of each attempt, which is worth knowing
-- before reading it as a number.
lights :: SdOut -> Bool -> Bit -> Bit -> Leds
lights o gaveUp cd wp =
       pack (boolToBit (sdStage o == Ready))
   ++# pack (boolToBit gaveUp)
   ++# (0 :: BitVector 4)
   ++# pack wp
   ++# pack cd
   ++# pack (sdFault o)
   ++# pack (sdStage o)

-- | The board design. Both periods are parameters for the same reason
-- 'Blinky.blinky''s are: so a simulation can pick small ones.
sdDemo
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ SPI half period in cycles minus one; 124 is 400 kHz at 100 MHz.
  -> Unsigned 32
  -- ^ Cycles - 1 that each display digit is held lit.
  -> Signal dom Bit  -- ^ MISO
  -> Signal dom Bit  -- ^ card detect
  -> Signal dom Bit  -- ^ write protect
  -> Signal dom (Bit, Bit, Bit, BitVector 16, BitVector 7, BitVector 4, Bit)
sdDemo half dwell miso cd wp =
  bundle (sdCs <$> out, sdSck <$> out, sdMosi <$> out, leds, seg, anode, pure high)
 where
  out  = sdCard half miso
  leds = lights <$> out <*> gaveUp <*> cd <*> wp

  -- The last two bytes of the block, kept after the read has finished. Bytes
  -- arrive in order, so shifting them in leaves byte 510 above byte 511.
  word = register 0 (keep <$> word <*> (sdData <$> out))
  keep w (Just (i, b)) | i >= 510 = shiftL w 8 .|. zeroExtend b
  keep w _                        = w

  -- A failed attempt is a passing state -- the controller goes straight back to
  -- trying -- so both the fact of it and the diagnostic have to be latched to be
  -- readable. Once a read succeeds the diagnostic is no longer interesting.
  failing = (== Failed) . sdStage <$> out
  ready   = (== Ready) . sdStage <$> out
  seen    = register False (failing .||. seen)
  gaveUp  = seen .&&. (not <$> ready)
  report  = regEn 0 failing (diagnose <$> out)
  diagnose o = 0xF000
                 .|. shiftL (zeroExtend (pack (sdFault o))) 8
                 .|. zeroExtend (sdR1 o)

  (seg, anode) = display (prescaler dwell) (hexDigits <$> mux gaveUp report word)

-- | 400 kHz on the card -- the fastest a card may be clocked before it is
-- initialised, and fast enough that the 512-byte block takes about 11 ms. Each
-- display digit is held for 100e3 cycles (1 ms), giving a 250 Hz refresh.
--
-- btnC arrives through 'resetGlitchFilter' at 'Settle', for the reason
-- 'Basys3.settle' gives: this design has no buttons of its own, but btnC is its
-- retry button, and an undebounced one starts an attempt per bounce rather than
-- per press -- so the LEDs would flicker through several initialisations and only
-- the last of them would be the one you asked for.
topEntity
  :: Clock Basys3
  -> Reset Basys3
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 (Bit, Bit, Bit, BitVector 16, BitVector 7, BitVector 4, Bit)
topEntity clk rst miso cd wp =
  withClockResetEnable clk (resetGlitchFilter (SNat @Settle) clk rst) enableGen
    (sdDemo 124 99_999 miso cd wp)
{-# NOINLINE topEntity #-}
{-# ANN topEntity
  (Synthesize
    { t_name   = "sddemo"
    , t_inputs = [ PortName "clk"
                 , PortName "rst"
                 , PortName "sd_miso"
                 , PortName "sd_cd"
                 , PortName "sd_wp"
                 ]
    , t_output = PortProduct ""
                   [ PortName "sd_cs"
                   , PortName "sd_sck"
                   , PortName "sd_mosi"
                   , PortName "led"
                   , PortName "seg"
                   , PortName "an"
                   , PortName "dp"
                   ]
    }) #-}
