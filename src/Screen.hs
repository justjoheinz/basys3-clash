{-|
What is on the screen: colour, at whatever depth the pixels were stored at, and
the handful of patterns that need no memory to draw.

"Protocol.VGA" says /when/ each pixel happens and is re-exported from here, so a
design needs only this module and the board. This one says what each pixel is
worth. The split is the same one "Serial" makes over "Protocol.UART": the wire
does not care, and everything that does care is on this side of it.

__Depth is a parameter.__ 'Rgb' carries any number of bits per channel, and the
board's connector is one instance of it -- 'Basys3.Colour' is @'Rgb' 4@, because a
Basys3's VGA port is a four-bit resistor DAC per channel. The four conversions
below are the depths a pixel is plausibly /stored/ at, each landing on the board's
four bits: one bit for line art, four for greyscale, eight as 3:3:2 when a byte
per pixel is the budget, and twelve when there is room for everything the DAC can
show. Which of them a design wants is the same question as how big its pixels are
going to be, and both are answered by whatever eventually holds them.

Widening is by repeating a value's own top bits into the new low ones, never by
zero-padding. @0b111@ becomes @0b1111@ and not @0b0111@, so full scale stays full
scale and white stays white rather than going 7\/8 grey.

__The patterns stay one level of logic deep.__ Shifts and comparisons only, no
multiply and no divide, which is 'Ascii.decDigits''s lesson applied before rather
than after measuring: a pixel is 40 ns at 'Basys3.dot' against the 10 ns
everything else in this library is measured against, and there is no reason to
spend any of it. A divider in the pixel path is how that budget gets lost.

Text is next door in "Screen.Font", not here and not re-exported, because unlike
everything below it costs a block RAM -- 2 KB of unscii 8x8, and the arithmetic that
turns a character code into a pixel.

Unprefixed, as "Ascii", "Serial" and "Latch" are: it is not a wire, not a class of
device and not a Pmod.
-}
module Screen
  ( module Protocol.VGA
    -- * Colour
  , Rgb (..)
    -- * Pixels as they were stored
  , mono
  , grey
  , rgb332
  , rgb444
    -- * Colours worth a name
  , black
  , white
  , red
  , green
  , blue
  , cyan
  , magenta
  , yellow
    -- * Patterns that need no memory
  , bands
  , checker
  , border
  ) where

import Clash.Prelude

import Protocol.VGA

-- | A colour, @n@ bits per channel. @'Rgb' 4@ is what this board's DAC can show;
-- @'Rgb' 8@ is what a photograph arrives as.
--
-- Fields are prefixed as "Protocol.UART"'s and "Pmod.SdCard"'s are, which is also
-- what leaves the bare words 'red', 'green' and 'blue' free to be the colours.
data Rgb n = Rgb
  { rgbRed   :: BitVector n
  , rgbGreen :: BitVector n
  , rgbBlue  :: BitVector n
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Show, Eq)

-- | One bit per pixel: ink or paper, and the caller decides which two colours
-- those are by not using this and writing @if lit then 'cyan' else 'black'@
-- instead. This is the black-and-white case, which is most line art.
mono :: KnownNat n => Bool -> Rgb n
mono lit = if lit then white else black

-- | One channel's worth of bits as a grey: the same level on all three.
--
-- Naturally depth-polymorphic, unlike the packed formats below, because grey is
-- the one case where the stored value already /is/ a channel.
grey :: BitVector n -> Rgb n
grey v = Rgb v v v

-- | A byte as 3:3:2 -- @RRRGGGBB@, red in the high bits -- which is the usual way
-- to spend exactly one byte on a pixel. 256 colours, and blue gets the short
-- channel because the eye minds least.
rgb332 :: BitVector 8 -> Rgb 4
rgb332 b = Rgb (wider3 r) (wider3 g) (wider2 bl)
 where
  (r, g, bl) = bitCoerce b :: (BitVector 3, BitVector 3, BitVector 2)

  -- Repeat the top bits downwards rather than padding with zeros, so 0b111 and
  -- 0b11 both reach 0b1111 and the brightest pixel a byte can hold is the
  -- brightest the DAC can show.
  wider3 v = v ++# pack (msb v)
  wider2 v = v ++# v

-- | Twelve bits as the DAC's own 4:4:4, red in the high bits. Everything the
-- connector can show, and the widest a pixel is worth storing on this board.
rgb444 :: BitVector 12 -> Rgb 4
rgb444 = bitCoerce

-- | Blanking level, and what 'Basys3.vgaPins' forces outside the visible area.
black :: KnownNat n => Rgb n
black = Rgb 0 0 0

-- | Every channel at full scale.
white :: KnownNat n => Rgb n
white = Rgb maxBound maxBound maxBound

-- | Red at full scale, the others dark.
red :: KnownNat n => Rgb n
red = Rgb maxBound 0 0

-- | Green at full scale, the others dark.
green :: KnownNat n => Rgb n
green = Rgb 0 maxBound 0

-- | Blue at full scale, the others dark.
blue :: KnownNat n => Rgb n
blue = Rgb 0 0 maxBound

-- | Green and blue: the complement of 'red'.
cyan :: KnownNat n => Rgb n
cyan = Rgb 0 maxBound maxBound

-- | Red and blue: the complement of 'green'.
magenta :: KnownNat n => Rgb n
magenta = Rgb maxBound 0 maxBound

-- | Red and green: the complement of 'blue'.
yellow :: KnownNat n => Rgb n
yellow = Rgb maxBound maxBound 0

-- | Vertical bars, one palette entry every @2 ^ shift@ pixels.
--
-- A shift rather than a width so the whole thing is one right shift and one
-- comparison, with no divider anywhere near the pixel path. The numbers work out
-- exactly for this board: @'bands' 6@ with a ten-entry palette is ten 64-pixel
-- bars, which is 640.
--
-- The last entry extends to the right if the palette runs out before the line
-- does, rather than reading off the end of it -- so a palette that does not
-- divide the width is untidy instead of undefined.
bands
  :: forall k n
   . (KnownNat k, 1 <= k)
  => Int
  -- ^ Bar width, as a power of two: 6 for 64 pixels.
  -> Vec k (Rgb n)
  -> Coord
  -- ^ x, from 'Protocol.VGA.scanAt'.
  -> Rgb n
bands wide palette x = palette !! min (shiftR x wide) (natToNum @(k - 1))

-- | A checkerboard of @2 ^ shift@ squares in two colours.
--
-- One bit of x against one bit of y, which is the cheapest pattern there is and
-- the most useful for bring-up: it is wrong in a way you can see from across the
-- room if either counter is miscounting, and both colours appear on every line.
checker
  :: Int
  -- ^ Square size, as a power of two.
  -> Rgb n
  -> Rgb n
  -> (Coord, Coord)
  -- ^ @(x, y)@, from 'Protocol.VGA.scanAt'.
  -> Rgb n
checker side a b (x, y)
  | testBit x side == testBit y side = a
  | otherwise                       = b

-- | True while the beam is within @width@ of the edge of a @w@ x @h@ picture.
--
-- A predicate rather than a colour so it composes with whichever two colours are
-- wanted: @'mono' . 'border' 4 (640, 480)@ outlines the visible area in white,
-- which is the one pattern that shows whether a monitor is cropping.
border
  :: Coord
  -- ^ How thick.
  -> (Coord, Coord)
  -- ^ The visible size, @(w, h)@.
  -> (Coord, Coord)
  -- ^ @(x, y)@, from 'Protocol.VGA.scanAt'.
  -> Bool
border width (w, h) (x, y) =
  x < width || y < width || x >= w - width || y >= h - width
