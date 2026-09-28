{-|
Text as bytes. A string literal as a 'Vec' of them, a nibble as the character
that names it, that character read back, and the two bytes that end a line.

Every function here is pure and clock-free, which is the point of the module:
these are the spellings, and "Serial" is what puts them on a wire. Splitting it
that way means a format can be checked by @cabal test@ without simulating
anything -- @'line' ('hex' v)@ is a list comparison, not a trace.

This module is deliberately outside the @Protocol@, @Peripheral@ and @Pmod@
namespaces. It is about text, not about a wire, a class of device, or something
you can plug into a header: nothing in it names a baud rate, a pin or a clock,
and it would feed a display as happily as it feeds a UART.
-}
module Ascii
  ( ascii
  , hex
  , hexChar
  , hexNibble
  , dec
  , decDigits
  , line
  ) where

import Clash.Prelude

import Data.Char             (isAscii, ord)
import Language.Haskell.TH   (ExpQ)

-- | A string literal as the bytes it stands for, ready to splice into a design:
--
-- @
-- greeting :: 'Vec' 7 ('BitVector' 8)
-- greeting = $('ascii' "Hello\\r\\n")
-- @
--
-- Template Haskell because a 'Vec' carries its length in its type, so the
-- length has to be settled at compile time -- and because that is the last
-- moment at which a character this cannot represent is still an error rather
-- than a quietly truncated byte.
ascii :: String -> ExpQ
ascii s
  | (c : _) <- filter (not . isAscii) s =
      fail ("ascii: " <> show c <> " is not an ASCII character")
  | otherwise = listToVecTH (fromIntegral . ord <$> s :: [BitVector 8])

-- | A nibble as the ASCII digit that names it, in upper case to match what the
-- seven-segment display makes of the same value. @'A' - 10@ is @0x37@.
hexChar :: Unsigned 4 -> BitVector 8
hexChar n
  | n < 10    = 0x30 + zeroExtend (pack n)
  | otherwise = 0x37 + zeroExtend (pack n)

-- | The other direction, accepting either case, and 'Nothing' for everything
-- else -- which is most of what a terminal sends.
hexNibble :: BitVector 8 -> Maybe (Unsigned 4)
hexNibble c
  | c >= 0x30 && c <= 0x39 = Just (unpack (resize (c - 0x30)))  -- '0'..'9'
  | c >= 0x41 && c <= 0x46 = Just (unpack (resize (c - 0x37)))  -- 'A'..'F'
  | c >= 0x61 && c <= 0x66 = Just (unpack (resize (c - 0x57)))  -- 'a'..'f'
  | otherwise              = Nothing

-- | A word as its hex digits, most significant first -- reading order, so the
-- 'Vec' can go straight onto a wire:
--
-- @
-- word :: 'BitVector' 16 -> 'Vec' 6 ('BitVector' 8)
-- word = 'line' . 'hex'
-- @
--
-- That signature is doing real work: @n@ is solved from the result, so a caller
-- that names the type it wants needs no type application. Without one, @4 * n@
-- leaves the digit count ambiguous.
--
-- 'Peripheral.SevenSegment.hexDigits' is the same 'bitCoerce' with a 'reverse'
-- in front of it, because a display is indexed from its rightmost digit. That
-- @reverse@ is the whole difference between display order and reading order,
-- which is why this needs nothing from the display peripheral.
hex :: KnownNat n => BitVector (4 * n) -> Vec n (BitVector 8)
hex = map hexChar . bitCoerce

-- | A number as its decimal digits, most significant first -- the base-ten
-- counterpart of 'bitCoerce' into nibbles, which base sixteen gets for free and
-- base ten does not.
--
-- The digit count is the caller's, because nothing in the input decides it: 16
-- bits reach 65535, so five digits show every value and four show most of them.
-- A value too big for the digits given loses its most significant ones, the way a
-- narrowing 'resize' does -- @decDigits (12345 :: 'BitVector' 16) :: 'Vec' 4
-- ('Unsigned' 4)@ reads 2345.
--
-- The order is reading order, as 'hex' is, so
-- @'Peripheral.SevenSegment.display'@ wants a 'reverse' in front of it -- the
-- same difference that separates 'hex' from
-- 'Peripheral.SevenSegment.hexDigits'. Four digits are also all this board's
-- display has, which is why "Basys3" offers no decimal equivalent of
-- 'Basys3.showHex': a counter worth showing outgrows it, and silently dropping
-- the digit that says so is not something a library should choose for you.
--
-- __How:__ double dabble, one pass per input bit, most significant first. Every
-- digit doubles and a digit that would pass nine carries into the next -- which is
-- the shift-and-add-three trick, since adding three before a doubling is adding six
-- after it, and six is the gap between binary's sixteen and decimal's ten. One step
-- of it is @steps@ below, and there is nothing else in the function.
--
-- __What it costs:__ this is combinational, and its depth is @m@ -- one level of
-- logic per /input/ bit, not per digit. Measured on this board: 16 bits is about
-- 8 ns between registers, which place-and-route has reported as anything from 116 to
-- 127 MHz against the 100 MHz it has to make -- the spread is placement, and the
-- margin is what matters. So it fits, and it does not fit twice -- a design spelling
-- something much wider than this wants the conversion registered partway, and one
-- spelling two numbers wants to look at the report before believing it does not.
-- @steps@ is where that depth comes from, and why it is not three times as deep.
--
-- None of which applies to 'hex', for the reason base sixteen is used in the first
-- place: it is a 'bitCoerce' and costs nothing at all.
decDigits
  :: forall n m
   . (KnownNat n, KnownNat m)
  => BitVector m
  -> Vec n (Unsigned 4)
decDigits = foldl absorb (repeat 0) . bv2v
 where
  -- One input bit into the bottom of the decimal number. mapAccumR because the
  -- carry runs the other way from the digits: right to left is least significant
  -- first, and the bit arriving at the bottom is the first carry in.
  absorb digits b = snd (mapAccumR shiftIn b digits)

  shiftIn :: Bit -> Unsigned 4 -> (Bit, Unsigned 4)
  shiftIn carry d = bitCoerce (steps !! (pack d ++# pack carry))

-- | One double-dabble step, as the truth table it is: five bits in -- a decimal
-- digit and the bit arriving under it -- and five bits out, the digit's new value
-- with the bit that overflowed into the next digit on top.
--
-- __Why a table and not the arithmetic:__ written as @if d >= 5 then d + 3 else d@
-- and a shift, which is how the trick is usually explained, each step synthesises
-- to a four-bit adder. Yosys maps those onto the carry chain, and a carry chain per
-- step times one step per input bit was measured on this board at 25 ns, or 40 MHz
-- against the 100 MHz it has to make -- 'Sketch' failed timing outright. Five bits
-- in and five out is one level of LUTs instead, because one level of LUTs is
-- exactly what a six-input lookup table can do, and the same design then came in at
-- about 8 ns, or 125 MHz. Sixteen levels of LUT fit in a 10 ns clock; sixteen adders
-- do not.
--
-- The table is still the arithmetic, evaluated once at compile time rather than
-- sixteen times in silicon: @'indicesI'@ enumerates the five-bit input, and the
-- body below is the shift-and-add-three rule written out the readable way. Nothing
-- has to be trusted about a hand-typed table because there is no hand-typed table.
steps :: Vec 32 (BitVector 5)
steps = map (entry . bitCoerce) indicesI
 where
  entry :: (Unsigned 4, Bit) -> BitVector 5
  entry (d, carry) = pack (boolToBit (wide >= 10)) ++# truncateB (pack out)
   where
    -- Doubling the digit and dropping the bit in underneath it. A digit is 0..9,
    -- so this is 0..19, and anything from ten up is a carry into the next digit
    -- with the remainder left behind -- which is the same thing adding three
    -- before the doubling achieves, one step earlier.
    wide = shiftL (extend d) 1 + (if carry == high then 1 else 0) :: Unsigned 5
    out  = if wide >= 10 then wide - 10 else wide

-- | A number as the decimal text of it, leading zeros blanked:
--
-- @
-- counted :: 'Unsigned' 16 -> 'Vec' 7 ('BitVector' 8)
-- counted = 'line' . 'dec' . 'pack'
-- @
--
-- This is the @'print' 42@ that prints @42@. It cannot print @42@ and nothing
-- else, though: a 'Vec' carries its length in its type, so the width is fixed
-- and the spare digits go out as spaces rather than as nothing at all. Right
-- aligned, which is what a column of numbers in a terminal wants anyway.
--
-- Zero is one digit, not a row of spaces, so there is always something to read.
-- Values too big for the digits given behave as 'decDigits' says.
dec
  :: forall n m
   . (KnownNat n, 1 <= n, KnownNat m)
  => BitVector m
  -> Vec n (BitVector 8)
dec v = izipWith spell blanked digits
 where
  digits  = decDigits v :: Vec n (Unsigned 4)

  -- True while nothing but zeros has been seen, this digit included.
  blanked = snd (mapAccumL leading True digits)
  leading zeros d = let still = zeros && d == 0 in (still, still)

  spell i skip d
    | skip, i /= maxBound = 0x20  -- space
    | otherwise           = hexChar d

-- | Carriage return and line feed on the end, which is what a terminal wants
-- before it will start a new line. Both, and in that order: a bare line feed
-- leaves some terminals printing a staircase.
line :: Vec n (BitVector 8) -> Vec (n + 2) (BitVector 8)
line = (++ 0x0D :> 0x0A :> Nil)
