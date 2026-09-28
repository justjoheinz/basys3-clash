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

-- | Carriage return and line feed on the end, which is what a terminal wants
-- before it will start a new line. Both, and in that order: a bare line feed
-- leaves some terminals printing a staircase.
line :: Vec n (BitVector 8) -> Vec (n + 2) (BitVector 8)
line = (++ 0x0D :> 0x0A :> Nil)
