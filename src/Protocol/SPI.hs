{-|
A byte-oriented SPI master in mode 0 (CPOL=0, CPHA=0): SCK idles low, the
peripheral samples MOSI on the rising edge and this master samples MISO on that
same edge. Bytes go out and come in most significant bit first.

The master is deliberately dumb -- one byte at a time, no notion of what the
bytes mean -- so whoever knows the protocol can be read as a protocol
description. It does not drive chip select either: which device is addressed,
and for how long, is not something a byte pipe can know.

Fixed here, and worth parameterising if a peripheral ever needs otherwise: the
eight-bit transfer width, and mode 0. The SCK period is /not/ fixed -- it is an
argument, which is what lets the same circuit run slowly on the board and at one
edge every two cycles in a test bench.

The @Protocol@ namespace is for bus masters like this one: what belongs here is
timing and framing that any device on the bus shares, never anything about a
particular device. Its first user is "Pmod.SdCard".
-}
module Protocol.SPI
  ( SpiOut(..)
  , spiMaster
  ) where

import Clash.Prelude

-- | What the master drives, and what it has heard.
data SpiOut = SpiOut
  { spiSck  :: Bit
  , spiMosi :: Bit
  , spiRx   :: Maybe (BitVector 8)
    -- ^ 'Just' during the single cycle in which a transfer completes.
  , spiIdle :: Bool
    -- ^ True when a byte offered to 'spiMaster' this cycle would be accepted.
    -- The cycle a transfer completes is idle too, so a consumer may see 'spiRx'
    -- and start the next byte without a gap.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | The shift registers, the bit counter, and where we are in the SCK period.
data Spi = Spi
  { sckHigh   :: Bool
  , countdown :: Unsigned 16  -- ^ cycles left in this half period
  , bitsLeft  :: Index 9      -- ^ 0 when idle
  , txShift   :: BitVector 8
  , rxShift   :: BitVector 8
  , rxValid   :: Bool
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @spiMaster half tx miso@ transfers a byte whenever one is offered on @tx@.
--
-- Data is presented on MOSI half a period before the first rising edge, so a
-- peripheral sampling on that edge sees a settled line. Both shift registers are
-- most significant bit first. Between transfers MOSI idles high.
spiMaster
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ Clock cycles per half SCK period, minus one, so SCK runs at
  -- @f \/ (2 * (half + 1))@: at 100 MHz, 124 gives 400 kHz.
  -> Signal dom (Maybe (BitVector 8))
  -- ^ A byte to transfer. Ignored unless 'spiIdle' is set.
  -> Signal dom Bit
  -- ^ MISO, sampled on the rising edge of SCK.
  -> Signal dom SpiOut
spiMaster half tx miso = moore step out initial (bundle (tx, miso))
 where
  initial = Spi { sckHigh   = False
                , countdown = 0
                , bitsLeft  = 0
                , txShift   = maxBound
                , rxShift   = 0
                , rxValid   = False
                }

  -- Moore, not Mealy: the pins follow the registers, so MOSI and SCK never
  -- glitch off a combinational path, and nothing the peripheral drives can feed
  -- through to the pins within a cycle.
  out s = SpiOut
    { spiSck  = boolToBit (sckHigh s)
    , spiMosi = if bitsLeft s == 0 then high else msb (txShift s)
    , spiRx   = if rxValid s then Just (rxShift s) else Nothing
    , spiIdle = bitsLeft s == 0
    }

  step s (offered, sdi)
    -- Idle: take a byte if one is on offer, and present its first bit.
    | bitsLeft s == 0 = case offered of
        Just b  -> s { bitsLeft = 8, txShift = b, countdown = half
                     , sckHigh = False, rxValid = False }
        Nothing -> s { rxValid = False }
    -- Waiting out half a period.
    | countdown s /= 0 = s { countdown = countdown s - 1, rxValid = False }
    -- Rising edge: whatever the peripheral put on MISO is valid now.
    | not (sckHigh s) = s { sckHigh   = True
                          , countdown = half
                          , rxShift   = shiftL (rxShift s) 1 .|. zeroExtend (pack sdi)
                          , rxValid   = False
                          }
    -- Falling edge: shift the next bit out, and report the byte after the
    -- eighth. rxShift is already complete -- its last bit arrived on the rising
    -- edge just gone.
    | otherwise = s { sckHigh   = False
                    , countdown = half
                    , txShift   = shiftL (txShift s) 1
                    , bitsLeft  = bitsLeft s - 1
                    , rxValid   = bitsLeft s == 1
                    }
