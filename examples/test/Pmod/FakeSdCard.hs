{-|
A pretend SD card: enough of one to drive "Pmod.SdCard" through its whole
initialisation sequence and a block read inside @cabal test@, with no hardware
and no HDL simulator.

It is a real SPI slave, shifting bits on the same edges a card does, so the test
covers the bit-level timing of "Protocol.SPI" as well as the protocol above it.
What it is not is a model of a card's misbehaviour: it answers promptly, never
reports an error, and claims to be a high-capacity card. Timeouts and error
tokens are 'Pmod.SdCard''s problem and are not exercised here.

This module lives in the test suite rather than the library because nothing here
is meant to be synthesised. It keeps the namespace of the module it stands in for,
so the double sits next to the real thing.
-}
module Pmod.FakeSdCard
  ( fakeCard
  , sectorByte
  ) where

import Clash.Prelude

-- | What the card owes the master, byte by byte, after a command frame.
data Reply
  = Silent                            -- ^ nothing asked: MISO idles high
  | Status (BitVector 8)              -- ^ R1
  | Tail (BitVector 8) (BitVector 32) -- ^ R1 and four more bytes: R3 or R7
  | Sector (BitVector 8)              -- ^ R1, a pause, a token, then a block
  deriving (Generic, NFDataX, Show, Eq)

data Card = Card
  { sckWas   :: Bool
  , rxBits   :: Unsigned 4    -- ^ bits of the current byte received so far
  , rxShift  :: BitVector 8
  , txShift  :: BitVector 8
  , frameBuf :: BitVector 48  -- ^ the last six bytes seen
  , toGo     :: Unsigned 3    -- ^ bytes still to come in this command frame
  , reply    :: Reply
  , pos      :: Unsigned 10   -- ^ byte index within 'reply'
  , polls    :: Unsigned 4    -- ^ ACMD41s answered with "still busy"
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @fakeCard (cs, sck, mosi)@ drives MISO.
--
-- Everything happens on the rising edge of SCK: the master samples MISO there
-- too, but it samples the value the card registered a cycle or more earlier, so
-- the two never race.
fakeCard
  :: HiddenClockResetEnable dom
  => Signal dom (Bit, Bit, Bit)
  -> Signal dom Bit
fakeCard = moore step (msb . txShift) initial
 where
  initial = Card { sckWas   = False
                 , rxBits   = 0
                 , rxShift  = 0
                 , txShift  = maxBound
                 , frameBuf = 0
                 , toGo     = 0
                 , reply    = Silent
                 , pos      = 0
                 , polls    = 0
                 }

  step c (cs, sck, mosi)
    -- Deselected: a real card ignores the clock and releases MISO, which the
    -- Pmod's pull-up then holds high.
    | cs == high = c { sckWas = sckHigh, rxBits = 0, toGo = 0, txShift = maxBound }
    | rising, rxBits c == 7 = byteDone rx c { sckWas = True, rxBits = 0, rxShift = rx }
    | rising = c { sckWas  = True
                 , rxBits  = rxBits c + 1
                 , rxShift = rx
                 , txShift = shiftL (txShift c) 1
                 }
    | otherwise = c { sckWas = sckHigh }
   where
    sckHigh = sck == high
    rising  = sckHigh && not (sckWas c)
    rx      = shiftL (rxShift c) 1 .|. zeroExtend (pack mosi)

-- | A whole byte arrived. Decide what the next byte out will be and present its
-- most significant bit, which the master samples on the next rising edge.
byteDone :: BitVector 8 -> Card -> Card
byteDone b c
  -- In the middle of a command frame; the card says nothing until it ends.
  | toGo c > 1  = load c { frameBuf = buf, toGo = toGo c - 1, reply = Silent, pos = 0 }
  | toGo c == 1 = load (decode buf c { frameBuf = buf, toGo = 0, pos = 0 })
  -- A command frame always starts with the bits 01.
  | slice d7 d6 b == 0b01 = load c { frameBuf = buf, toGo = 5, reply = Silent, pos = 0 }
  | otherwise = load c { frameBuf = buf, pos = pos c + 1 }
 where
  buf = shiftL (frameBuf c) 8 .|. zeroExtend b

load :: Card -> Card
load c = c { txShift = replyByte (reply c) (pos c) }

-- | Which reply a command earns. The card reports itself busy for two ACMD41s
-- before declaring itself ready, so the retry loop in "Pmod.SdCard" is exercised
-- rather than merely present.
decode :: BitVector 48 -> Card -> Card
decode buf c = case slice d45 d40 buf of
  0  -> c { reply = Status 0x01 }              -- CMD0: idle, now in SPI mode
  8  -> c { reply = Tail 0x01 0x0000_01AA }    -- CMD8: voltage fine, pattern echoed
  55 -> c { reply = Status 0x01 }              -- CMD55
  41 | polls c >= 2 -> c { reply = Status 0x00 }
     | otherwise    -> c { reply = Status 0x01, polls = polls c + 1 }
  58 -> c { reply = Tail 0x00 0xC0FF_8000 }    -- CMD58: powered up, high capacity
  -- CMD17. The argument is ignored: this card is one block, at every address.
  17 -> c { reply = Sector 0x00 }
  _  -> c { reply = Status 0x05 }              -- illegal command

-- | Byte @n@ of a reply, counting from the first byte after the command frame.
-- Byte zero is the pause a card is allowed before it answers (Ncr), which keeps
-- "Pmod.SdCard"'s polling loop honest.
replyByte :: Reply -> Unsigned 10 -> BitVector 8
replyByte r n = case r of
  Silent -> 0xFF
  Status s
    | n == 1    -> s
    | otherwise -> 0xFF
  Tail s t
    | n == 1              -> s
    | n >= 2 && n <= 5    -> (bitCoerce t :: Vec 4 (BitVector 8)) !! (n - 2)
    | otherwise           -> 0xFF
  Sector s
    | n == 1               -> s
    | n == 4               -> 0xFE   -- the start-of-block token
    | n >= 5 && n <= 516   -> sectorByte (n - 5)
    | n == 517 || n == 518 -> 0x00   -- the block's CRC16, which nobody checks
    | otherwise            -> 0xFF

-- | What this card has in block zero: a ramp, so a byte order mistake shows up
-- at once, ending in the 0x55AA signature a real partitioned card has at bytes
-- 510 and 511.
sectorByte :: Unsigned 10 -> BitVector 8
sectorByte i
  | i == 510  = 0x55
  | i == 511  = 0xAA
  | otherwise = resize (pack i)
