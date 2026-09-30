{-|
VGA timing: the two sync pulses a monitor locks onto, and where the beam is while
they run.

A VGA cable carries no clock and no addresses. The monitor is told only when a
line ends and when a frame ends, and it works out where every pixel goes by
counting time from those two edges -- so the whole of this module is one counter
per axis and the comparators that turn them into the two syncs. Colour is not
here at all; it goes out on its own three channels, and what to paint is
"Screen"'s business.

Each axis is four spans in a fixed order: the pixels the monitor shows, a blank
/front porch/, the sync pulse itself, and a blank /back porch/. The porches are
not padding -- they are the time a CRT's beam needed to fly back, and every
monitor since has kept them because the standard did. Nothing may be painted
outside the visible span, which is why 'scanAt' is a 'Maybe' rather than a pair
of counters a design is trusted to range-check.

Timings are values, not types. A 'Mode' is a record of plain numbers, so the
board's 640x480 and a test's 8x6 are the same type and a whole frame of the
latter is 48 samples -- the same trade @Blinky.blinky@ makes with its period, and
the only reason any of this is testable. 640x480 is 420,000 pixels a frame.

The @Protocol@ namespace is for wire timing and framing that everything on the
link shares, never anything about what is being sent: "Protocol.UART" and
"Protocol.SPI" are the others. This module knows what a sync pulse is and does
not know what a pixel is worth -- see "Screen" for that, and 'Basys3.screen' for
this board's 640x480 with its pixel rate already applied.
-}
module Protocol.VGA
  ( -- * A mode
    Coord
  , Polarity (..)
  , Timing (..)
  , Mode (..)
  , vga640x480at60
    -- * What a mode adds up to
  , totals
  , refresh
    -- * Driving the connector
  , Scan (..)
  , scan
  ) where

import Clash.Prelude

-- | A position along either axis, in pixels or in lines.
--
-- Eleven bits where 640x480 needs ten: its totals are 800 and 525, and 2047
-- leaves room for every mode up to 1280x1024 (1688 x 1066) without this synonym
-- having to change. Two flip-flops for the two counters in 'scan', which is not a
-- price worth optimising.
type Coord = Unsigned 11

-- | Which way round a sync pulse is. VESA's own word for it, and it varies by
-- mode rather than by board: 640x480 at 60 Hz is 'Negative' on both axes, while
-- 800x600 at 60 Hz is 'Positive' on both.
--
-- Not Clash's 'ResetPolarity', whose constructors these would otherwise be called
-- after -- @ActiveLow@ and @ActiveHigh@ are already taken by the reset that
-- 'Basys3.onBoard' wires up, and a sync pulse is not a reset.
data Polarity
  = Negative
    -- ^ The line idles high and the pulse pulls it low.
  | Positive
    -- ^ The line idles low and the pulse drives it high.
  deriving (Generic, NFDataX, Show, Eq)

-- | One axis of a mode, in the order the four spans actually occur.
--
-- Every field is a count of pixels on the horizontal axis and of whole lines on
-- the vertical one, which is the one thing about VGA timing tables that catches
-- people: the vertical numbers are lines, so a two-line sync pulse is 1600 pixel
-- periods long.
data Timing = Timing
  { visible  :: Coord
    -- ^ Pixels the monitor shows. The only span 'scanAt' reports a position in.
  , front    :: Coord
    -- ^ The front porch: blank, after the visible span and before the pulse.
  , pulse    :: Coord
    -- ^ The sync pulse.
  , back     :: Coord
    -- ^ The back porch: blank, after the pulse and before the next visible span.
  , polarity :: Polarity
    -- ^ Which way the pulse goes.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | A whole mode: both axes. What it does not carry is its pixel clock, because
-- nothing in the counters needs it -- the rate arrives as the enable handed to
-- 'scan', and what it should be is 'refresh''s question.
data Mode = Mode
  { horizontal :: Timing
  , vertical   :: Timing
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | 640x480 at 60 Hz: the mode this board can actually clock, and the only one
-- defined here.
--
-- It wants a 25.175 MHz pixel clock. The Basys3's 100 MHz divides to 25.000 MHz,
-- which is 0.7% slow -- outside VESA's tolerance, giving 59.52 Hz rather than
-- 59.94 -- and is what every monitor anyone has tried this on accepts anyway.
-- 'Basys3.dot' is that divide, and it is a clock /enable/ rather than a second
-- clock domain: see 'Basys3.pixel' for why that matters to this toolchain.
--
-- Every larger mode needs a pixel clock that 100 MHz does not divide to -- 40 MHz
-- for 800x600, 65 for 1024x768, 108 for 1280x1024 -- and therefore an MMCM, which
-- the openXC7 flow does not support well enough to rely on. Adding one here is
-- four numbers and a 'Polarity' once there is a clock for it; shipping one that
-- cannot be clocked would be shipping a trap.
vga640x480at60 :: Mode
vga640x480at60 = Mode
  { horizontal = Timing { visible = 640, front = 16, pulse = 96, back = 48
                        , polarity = Negative }
  , vertical   = Timing { visible = 480, front = 10, pulse =  2, back = 33
                        , polarity = Negative }
  }

-- | The four spans of one axis, added up: how far its counter runs.
total :: Timing -> Coord
total t = visible t + front t + pulse t + back t

-- | Pixels per line and lines per frame, both including the blanking. For
-- 'vga640x480at60' that is @(800, 525)@, so a frame is 420,000 pixel periods.
--
-- Pure, and no part of any circuit: it is here so a test can check a mode's
-- numbers add up without simulating one.
totals :: Mode -> (Coord, Coord)
totals m = (total (horizontal m), total (vertical m))

-- | Frames per second, given a mode and its pixel clock in Hz.
--
-- @'refresh' 'vga640x480at60' 25e6@ is 59.52, and at the nominal 25.175e6 it is
-- 59.94. The gap between those two is the whole cost of dividing 100 MHz by four
-- instead of generating 25.175 MHz.
refresh :: Mode -> Double -> Double
refresh m hz = hz / (fromIntegral x * fromIntegral y)
 where
  (x, y) = totals m

-- | Everything the connector and the design need to know for the pixel period
-- the beam is currently in.
data Scan = Scan
  { scanHsync :: Bit
    -- ^ The horizontal sync pin, already the right way round for the mode's
    -- 'polarity'.
  , scanVsync :: Bit
    -- ^ The vertical sync pin, likewise.
  , scanAt    :: Maybe (Coord, Coord)
    -- ^ Where to paint, as @(x, y)@ from the top left of the visible area, and
    -- 'Nothing' throughout blanking -- which is most of the time: 420,000 pixel
    -- periods a frame carry 307,200 pixels.
    --
    -- A monitor measures its own black level during blanking, so anything but
    -- black there washes the whole picture out. 'Basys3.vgaPins' is where that is
    -- enforced, so that no design can paint through a porch by forgetting to look
    -- at this.
  , scanFrame :: Bool
    -- ^ True throughout the first pixel of each frame. One /pixel period/, so
    -- four clock cycles at 'Basys3.dot', not one cycle -- gate it with the same
    -- enable that drives 'scan' if a single-cycle pulse is what is wanted.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | The whole timing generator: two counters, and the syncs derived from them.
--
-- The enable is the pixel rate. It advances the beam by one pixel each time it is
-- set and nothing happens on the cycles between, which is what lets a 25 MHz
-- raster live in a 100 MHz domain with no second clock and no crossing between
-- them -- @'scan' 'vga640x480at60' ('Basys3.prescaler' 3)@ on this board, and
-- @'pure' 'True'@ in a test, where one cycle is one pixel.
--
-- Moore, not Mealy, for the reason 'Protocol.UART.uartTx' gives: both syncs come
-- straight off a register, so nothing combinational upstream can put a glitch in
-- the middle of a pulse and cost the monitor its lock.
scan
  :: HiddenClockResetEnable dom
  => Mode
  -> Signal dom Bool
  -- ^ One pulse per pixel period.
  -> Signal dom Scan
scan m = moore step out initial
 where
  h = horizontal m
  v = vertical m

  -- The last valid position on each axis. Constants: a mode is a literal by the
  -- time this is synthesised, so neither is arithmetic in hardware.
  lastX = total h - 1
  lastY = total v - 1

  initial = (0, 0) :: (Coord, Coord)

  -- Raster order, and the only place either counter moves. Wrapping y at the end
  -- of the last line is what makes a frame a frame.
  step s@(x, y) en
    | not en     = s
    | x /= lastX = (x + 1, y)
    | y /= lastY = (0, y + 1)
    | otherwise  = (0, 0)

  out (x, y) = Scan
    { scanHsync = sync h x
    , scanVsync = sync v y
    , scanAt    = if x < visible h && y < visible v then Just (x, y) else Nothing
    , scanFrame = x == 0 && y == 0
    }

  -- The pulse sits between the two porches, so it starts once the visible span
  -- and the front porch are behind us and lasts for its own width. Outside it the
  -- line idles at the opposite level, which is the whole of what 'Polarity' says.
  sync t n
    | n >= from && n < from + pulse t = active
    | otherwise                       = complement active
   where
    from   = visible t + front t
    active = case polarity t of
      Negative -> low
      Positive -> high
