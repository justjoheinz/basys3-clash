{-|
A UART, both halves: the asynchronous serial framing that a USB-serial bridge
speaks on the far side of its cable, and on the Basys3 the whole of the host
link.

One frame is 8N1 -- a low start bit, eight data bits, a high stop bit, no parity
-- and the line idles high. There is no clock on the wire, which is what
/asynchronous/ means: both ends must already agree on the bit period, and the
receiver recovers everything else from the falling edge that starts a frame.

Data bits go least significant first. That is the one thing about this module
worth reading twice, because it is the opposite of "Protocol.SPI", where bytes go
most significant bit first. SPI has a clock line to hang the order off and so
never had to settle on one; a UART had to.

Fixed here, and worth parameterising only if something on the other end insists:
the eight-bit width, the single stop bit, no parity, and no flow control -- the
Basys3 does not bring RTS/CTS out to the fabric, so there would be nothing to
drive. The bit period is /not/ fixed. It is an argument, for the same reason
'Protocol.SPI.spiMaster''s period is: the board wants 115200 baud and a test
bench wants four cycles a bit.

Transmitter and receiver are separate circuits rather than one, because a UART is
genuinely full duplex: the two halves share no state, no timing and no byte, and
a design that only listens should build only the receiver. SPI's single
'Protocol.SPI.SpiOut' is the honest description of the opposite case, where one
transfer /is/ both directions at once.

The @Protocol@ namespace is for wire timing and framing that everything on the
link shares, never anything about what the bytes mean. Its other member is
"Protocol.SPI"; this module's first user is "IoDemo".
-}
module Protocol.UART
  ( UartTx(..)
  , UartRx(..)
  , uartTx
  , uartRx
  ) where

import Clash.Prelude

-- | What the transmitter drives, and whether it will take another byte.
data UartTx = UartTx
  { txLine :: Bit
    -- ^ The transmit pin. Idles high, including throughout reset.
  , txIdle :: Bool
    -- ^ True when a byte offered to 'uartTx' this cycle would be accepted.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | What the receiver has heard.
data UartRx = UartRx
  { rxByte  :: Maybe (BitVector 8)
    -- ^ 'Just' during the single cycle in which a frame's stop bit is sampled
    -- high.
  , rxError :: Bool
    -- ^ True for a single cycle when a stop bit was sampled low. No byte is
    -- reported for that frame. Latch it if it is to be displayed: almost always
    -- it means the two ends disagree about the bit period.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | The bit the pin is showing, the bits still to show, and where we are in the
-- current bit period.
data Tx = Tx
  { level   :: Bit          -- ^ what the pin reads; registered, so it cannot glitch
  , pending :: BitVector 8  -- ^ data bits not yet shown, least significant first
  , periods :: Index 11     -- ^ bit periods left in the frame, 0 when idle
  , holding :: Unsigned 16  -- ^ cycles left in this bit period
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @uartTx full offered@ sends a frame whenever a byte is offered and the line
-- is idle.
--
-- Each of the ten bit periods lasts exactly @full + 1@ cycles. A byte accepted
-- in cycle /r/ puts the start bit on the line in /r+1/ and the transmitter
-- reports idle again in @r + 1 + 10 * (full + 1)@, so offering a byte every time
-- 'txIdle' is set gives a frame pitch one cycle longer than the frame itself.
-- That one cycle is extra stop bit, which is legal 8N1 -- a stop bit may be long,
-- only its sample point matters -- and costs 0.01% of the throughput at 115200.
uartTx
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ Clock cycles per bit, minus one, so the line runs at @f \/ (full + 1)@:
  -- at 100 MHz, 867 gives 115200 baud. See 'Basys3.baud115200'.
  -> Signal dom (Maybe (BitVector 8))
  -- ^ A byte to send. Ignored unless 'txIdle' is set.
  -> Signal dom UartTx
uartTx full = moore step out initial
 where
  initial = Tx { level = high, pending = maxBound, periods = 0, holding = 0 }

  -- Moore, not Mealy, for the reason 'Protocol.SPI.spiMaster' gives: the pin
  -- follows a register, so nothing upstream can glitch the line mid-bit.
  out s = UartTx { txLine = level s, txIdle = periods s == 0 }

  step s bs
    -- Idle at mark. Take a byte if one is offered and drive its start bit; ten
    -- bit periods follow, being the start bit, eight data bits and the stop bit.
    -- Whatever 'holding' was left at is irrelevant here and never needs
    -- clearing, exactly as 'Protocol.SPI.spiMaster' leaves its countdown alone.
    | periods s == 0 = case bs of
        Just b  -> s { level = low, pending = b, periods = 10, holding = full }
        Nothing -> s { level = high }
    -- Holding the current bit.
    | holding s /= 0 = s { holding = holding s - 1 }
    -- The bit period is over, so show the next one, least significant first. The
    -- count runs 10 for the start bit, 9 down to 2 for the eight data bits, 1
    -- for the stop bit, 0 for idle -- so the @> 2@ test is what drives mark
    -- after the eighth data bit without needing a branch of its own.
    | otherwise = s { level   = if periods s > 2 then lsb (pending s) else high
                    , pending = shiftR (pending s) 1
                    , periods = periods s - 1
                    , holding = full
                    }

-- | Where the receiver is within a frame. The counter that says which data bit
-- is next lives in the phase that needs it, as 'Pmod.SdCard.Stage' does.
data Phase
  = Hunting
    -- ^ Line at mark; any low level is a candidate start bit.
  | Checking
    -- ^ Half a bit period into that candidate: is it still low?
  | Sampling (Index 8)
    -- ^ Which data bit the next sample point carries; 0 is the first one on the
    -- wire, and the least significant.
  | Stopping
    -- ^ The stop bit's sample point.
  | Recovering
    -- ^ Framing broke, or we have just come out of reset, so wait for the line
    -- to be at mark before hunting again.
  deriving (Generic, NFDataX, Show, Eq)

-- | The phase, the countdown to the next sample point, and the bits so far.
data Rx = Rx
  { phase     :: Phase
  , countdown :: Unsigned 16  -- ^ cycles left before the next sample point
  , gathered  :: BitVector 8  -- ^ bits so far, shifted in from the top
  , received  :: Maybe (BitVector 8)
  , broken    :: Bool
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @uartRx full line@ reports each byte the far end sends.
--
-- Where the samples land, counting from the cycle the falling edge is seen at
-- and writing @B@ for the bit period @full + 1@: the start bit is re-checked at
-- @0.5B@, the data bits are sampled at @1.5B@ to @8.5B@, and the stop bit at
-- @9.5B@. Every sample after the first is a whole bit period from the one
-- before, so all nine sit within half a bit of the middle of theirs.
--
-- That fixes the tolerance. A sample stays inside its bit while the accumulated
-- error is under half a bit period, so @9.5 * e < 0.5@: the two ends' rates may
-- differ by just under 5% before a sample lands in the wrong bit. Detecting the
-- edge costs up to one clock of that, which at 115200 on a 100 MHz clock is
-- 0.1% of a bit.
uartRx
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ Clock cycles per bit, minus one -- the same number the far end's
  -- transmitter uses. At least 1; on the board it is 'Basys3.baud115200'.
  -> Signal dom Bit
  -- ^ The receive pin, straight from the pad: this synchronises it itself.
  -> Signal dom UartRx
uartRx full raw = moore step out initial safe
 where
  -- The pin is driven by the far end's clock, not ours, so a single register
  -- sampling it could settle to neither level and hand a half-made decision to
  -- the logic behind it. Two of them is the price, and the two cycles of latency
  -- delay the falling edge and every sample point alike, so they add no skew.
  safe = register high (register high raw)

  -- Half a bit period, which is how far into the start bit the first sample
  -- goes. Rounding down keeps the sample inside the bit for any @full@.
  half = shiftR full 1

  initial = Rx { phase    = Recovering
               , countdown    = 0
               , gathered = 0
               , received = Nothing
               , broken   = False
               }

  out s = UartRx { rxByte = received s, rxError = broken s }

  -- Both reports last a single cycle, so every branch clears them.
  quiet s = s { received = Nothing, broken = False }

  step s line
    -- Idle. One clock of resolution on the edge is plenty when the sample it
    -- schedules is half a bit period away.
    | Hunting <- phase s =
        quiet (if line == low then s { phase = Checking, countdown = half } else s)
    -- Do not hunt for a start bit until the line has actually been at mark. A
    -- break, or a reset in the middle of somebody else's frame, would otherwise
    -- read as a stream of zero bytes.
    | Recovering <- phase s =
        quiet s { phase = if line == high then Hunting else Recovering }
    -- Counting down to the next sample point.
    | countdown s /= 0 = quiet s { countdown = countdown s - 1 }
    -- Half a bit period in. A real start bit is still low; a noise spike is not.
    | Checking <- phase s =
        quiet (if line == low
                 then s { phase = Sampling 0, countdown = full, gathered = 0 }
                 else s { phase = Hunting })
    -- Mid-bit. Shifting the sample in at the top is what makes least significant
    -- first come out right: the first bit received has been pushed down to bit 0
    -- by the time the eighth arrives.
    | Sampling n <- phase s = quiet s
        { phase    = if n == maxBound then Stopping else Sampling (n + 1)
        , countdown    = full
        , gathered = pack line ++# slice d7 d1 (gathered s)
        }
    -- By elimination the phase is 'Stopping'. The stop bit must be at mark; if
    -- it is not then we cannot say where the frame really began, so report the
    -- framing error rather than a byte, and wait for the line to settle.
    | line == high = (quiet s) { phase = Hunting,    received = Just (gathered s) }
    | otherwise    = (quiet s) { phase = Recovering, broken   = True }
