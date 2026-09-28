{-|
Driving a multiplexed seven-segment display: the digit decoder, the scan that
makes several digits look lit at once, and a way to get digits out of a word.

Nothing here is specific to a board or to a digit count. What it does assume is
the arrangement every cheap multi-digit display uses: the seven cathodes are
wired in parallel across all digits, one anode per digit selects which of them
the pattern applies to, and both are active low. Only one digit is ever really
lit; the eye does the rest.

The @Peripheral@ namespace is for blocks like this -- how to drive or read a
class of device, with the wiring of any particular board left to that board's
module. See "Basys3" for the concrete four-digit instance.
-}
module Peripheral.SevenSegment
  ( sevenSeg
  , display
  , hexDigits
  ) where

import Clash.Prelude

-- | Cathode pattern for one digit, CA in bit 0 through CG in bit 6. The display
-- is common anode, so the pattern is driven low-active. All sixteen values
-- decode -- 0-9 and A-F -- so any nibble can be shown as a hex digit.
sevenSeg :: Unsigned 4 -> BitVector 7
sevenSeg d = complement (table !! d)
 where
  --        0      1      2      3      4      5      6      7
  table =  0x3F :> 0x06 :> 0x5B :> 0x4F :> 0x66 :> 0x6D :> 0x7D :> 0x07
  --        8      9      A      b      C      d      E      F
        :> 0x7F :> 0x6F :> 0x77 :> 0x7C :> 0x39 :> 0x5E :> 0x79 :> 0x71
        :> Nil :: Vec 16 (BitVector 7)

-- | Scanning display driver: advances to the next digit on every enable pulse
-- and returns the cathode pattern plus the active-low digit enables.
--
-- Digits are ordered least significant first, so index 0 drives the first anode
-- -- on most boards the rightmost digit. Every digit must be visited often
-- enough that the eye integrates them: once per 1-16 ms is the usual range, so
-- for @n@ digits the enable wants to pulse at @n@ times that rate.
display
  :: forall n dom
   . (HiddenClockResetEnable dom, KnownNat n, 1 <= n)
  => Signal dom Bool
  -- ^ Step to the next digit.
  -> Signal dom (Vec n (Unsigned 4))
  -> (Signal dom (BitVector 7), Signal dom (BitVector n))
display en digits = (sevenSeg <$> digit, anode)
 where
  sel   = regEn (0 :: Index n) en (satSucc SatWrap <$> sel)
  digit = (!!) <$> digits <*> sel
  anode = complement . bit . fromEnum <$> sel

-- | Split a word into hex digits ready for 'display': index 0 is the least
-- significant nibble. @hexDigits (0x55AA :: BitVector 16)@ shows as @55AA@,
-- rightmost digit first.
hexDigits :: KnownNat n => BitVector (4 * n) -> Vec n (Unsigned 4)
hexDigits = reverse . bitCoerce
