{-|
Bringing an SD card up in SPI mode and reading block zero from it.

The protocol, briefly. A card powers up in SD mode and only switches to SPI when
it sees CMD0 with the chip select asserted, so the sequence is fixed:

  * at least 74 clocks with CS high, which is the card's own power-on ramp;
  * CMD0, GO_IDLE_STATE, which is what selects SPI mode;
  * CMD8, SEND_IF_COND, which both checks the voltage range and distinguishes
    version 2 cards -- version 1 cards reject it as an illegal command;
  * CMD55 followed by ACMD41, repeated until the card reports that it has
    finished initialising, which can take up to a second;
  * CMD58, READ_OCR, whose bit 30 says whether the card is addressed by block
    (SDHC and SDXC) or by byte (older, smaller cards);
  * CMD17, READ_SINGLE_BLOCK, which answers with a token and 512 bytes.

Every command is the same six bytes: @01@, a six-bit index, a 32-bit argument and
a CRC7 with a stop bit. Responses are one status byte (R1) whose top bit is
always zero, which is how you find it in the stream of @0xFF@ the card sends
while it thinks -- optionally followed by four more bytes (R3 and R7).

Block zero is address zero whether the card counts in blocks or in bytes, so
'sdCard' reads it without having to branch on the OCR. Anything else would.

Failure is not final: giving up at any stage starts the sequence over from the
power-on clocking, so an empty socket just keeps trying and a card inserted later
is picked up within a few milliseconds. Success is final -- once the block has
been read the bus is left alone.

The @Pmod@ namespace is for the add-on modules that plug into the board's Pmod
headers, one module per thing you can buy: this one is the Digilent Pmod SD. What
belongs here is the module's own protocol, not its pinout -- which header it is on
is a constraints question (@constraints\/PmodSD-J{A,B,C}.xdc@), and the card cares
about neither. It builds on "Protocol.SPI" for the wire timing.

The port /names/ are a different matter from the pinout, and they are here:
'sdPinsPort' and 'sdInputPorts' spell the six nets this module needs brought out,
and all three of those constraints files use those same six names. A design's
@topEntity@ should not be retyping them -- see "Basys3" for the rest of that
argument.
-}
module Pmod.SdCard
  ( Stage(..)
  , SdOut(..)
  , SdPins(..)
  , crc7
  , frameFor
  , commandFor
  , sdCard
  , sdPins
    -- * Naming the pins
  , sdInputPorts
  , sdPinsPort
  ) where

import Clash.Prelude

import Protocol.SPI (SpiOut (..), spiMaster)

-- | How far the card has been brought up. Doubles as a diagnostic: 'SdOut'
-- reports it, and the 'Sd' design shows it on the LEDs, which is why it is a plain
-- enumeration with a four-bit 'BitPack' encoding.
data Stage
  = PowerOn    -- ^ clocking with the card deselected, as its power-on needs
  | GoIdle     -- ^ CMD0:  reset, and switch the card into SPI mode
  | IfCond     -- ^ CMD8:  voltage range, and "are you a version 2 card?"
  | AppCmd     -- ^ CMD55: the escape prefix that makes the next command an ACMD
  | OpCond     -- ^ ACMD41: begin initialising; repeats until the card is ready
  | ReadOcr    -- ^ CMD58: block addressed or byte addressed?
  | ReadBlock  -- ^ CMD17: read block zero
  | Ready      -- ^ the block has been read
  | Failed     -- ^ gave up; 'sdFault' says where. Passed through briefly on the
               --   way back to 'PowerOn' for another attempt, so a design that
               --   wants to report it wants @'Latch.latch' ((== 'Failed') . 'sdStage'
               --   \<$\> out)@ -- see 'Sd'.
  deriving (Generic, NFDataX, BitPack, Show, Eq)

-- | Where the byte-level engine is within a stage.
data Phase
  = Priming (Unsigned 4)     -- ^ dummy bytes left to clock out, CS high
  | Sending (Unsigned 3)     -- ^ command bytes left to shift out
  | AwaitR1 (Unsigned 8)     -- ^ polls left before we give up on a response
  | AwaitTail (Unsigned 3)   -- ^ extra response bytes left (R3, R7)
  | AwaitToken (Unsigned 16) -- ^ polls left while the card fetches the block
  | Receiving (Unsigned 10)  -- ^ byte index within the block, then two CRC bytes
  | Releasing                -- ^ one byte with CS high, letting the card go
  | Halted                   -- ^ ready or failed; the bus is left alone
  deriving (Generic, NFDataX, Show, Eq)

-- | The sequencer's registers.
data Sd = Sd
  { stage    :: Stage
  , failedAt :: Stage
  , phase    :: Phase
  , frame    :: BitVector 48  -- ^ command being shifted out, most significant first
  , status   :: BitVector 8   -- ^ the R1 byte the card answered with
  , extra    :: BitVector 32  -- ^ the tail of an R3 or R7 response
  , attempts :: Unsigned 16   -- ^ ACMD41 polls so far
  , awaiting :: Bool          -- ^ a byte is in flight on the bus
  , streamed :: Maybe (Unsigned 10, BitVector 8)
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | What the sequencer knows. The SCK and MOSI pins come from the master, so
-- they are filled in by 'sdCard' rather than here.
data Progress = Progress
  { pStage :: Stage
  , pFault :: Stage
  , pR1    :: BitVector 8
  , pExtra :: BitVector 32
  , pData  :: Maybe (Unsigned 10, BitVector 8)
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Everything the design needs: the three pins to drive, and what the card has
-- said so far.
data SdOut = SdOut
  { sdCs    :: Bit
    -- ^ Chip select, active low.
  , sdSck   :: Bit
  , sdMosi  :: Bit
  , sdStage :: Stage
  , sdFault :: Stage
    -- ^ The stage that failed, meaningful once 'sdStage' is 'Failed'.
  , sdR1    :: BitVector 8
    -- ^ The most recent status byte. @0xFF@ means the card has not answered yet.
  , sdExtra :: BitVector 32
    -- ^ The tail of the last R3 or R7: CMD8's echo, then CMD58's OCR.
  , sdData  :: Maybe (Unsigned 10, BitVector 8)
    -- ^ Block bytes, streamed with their index as they arrive.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Just the three pins, for a @topEntity@ that has to bring them out to the
-- header.
--
-- Separate from 'SdOut' because only these three are wires: the rest of 'SdOut'
-- is what the card has said, which a design reports however it likes. A record
-- rather than a triple because all three are 'Bit' and so a triple of them is
-- three ways round that all typecheck -- and SCK swapped with MOSI is a card that
-- simply never answers.
data SdPins = SdPins
  { csPin   :: Bit
    -- ^ Chip select, active low.
  , sckPin  :: Bit
  , mosiPin :: Bit
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Show, Eq)

-- | The pins out of 'sdCard''s output.
sdPins :: SdOut -> SdPins
sdPins o = SdPins { csPin = sdCs o, sckPin = sdSck o, mosiPin = sdMosi o }

-- | What the module drives, in the order 'SdPins' names them. Flat inside a
-- design's output product, as @sd_cs@, @sd_sck@ and @sd_mosi@.
--
-- @'PortProduct' ""@ rather than @Basys3.ports@, which is the same function: this
-- module knows nothing about which board it is plugged into, and should not start
-- now.
sdPinsPort :: PortName
sdPinsPort =
  PortProduct "" [PortName "sd_cs", PortName "sd_sck", PortName "sd_mosi"]

-- | What the module needs read, in the order 'sdCard' and a design around it take
-- them: MISO, then the socket's two switches.
--
-- Card detect and write protect are not 'sdCard''s business -- it never looks at
-- them -- but they are wired to the header whether a design uses them or not, so
-- the names belong with the rest.
sdInputPorts :: [PortName]
sdInputPorts = [PortName "sd_miso", PortName "sd_cd", PortName "sd_wp"]

-- | CRC7 over a command's first five bytes, polynomial @x^7 + x^3 + 1@. Cards
-- ignore the CRC of most commands in SPI mode, but CMD0 and CMD8 are sent before
-- that relaxation applies, so computing it properly is less trouble than
-- hard-coding the two magic bytes everyone else hard-codes.
crc7 :: KnownNat n => BitVector n -> BitVector 7
crc7 = foldl step 0 . bv2v
 where
  step crc b
    | (msb crc `xor` b) == high = shiftL crc 1 `xor` 0x09
    | otherwise                 = shiftL crc 1

-- | A six-byte command frame: the start and transmission bits, the command
-- index, its argument, and the CRC7 with its stop bit.
frameFor :: BitVector 6 -> BitVector 32 -> BitVector 48
frameFor cmd arg = payload ++# (crc7 payload ++# (1 :: BitVector 1))
 where
  payload = (0b01 :: BitVector 2) ++# cmd ++# arg

-- | The command each stage sends. Stages that send none never reach 'Sending'.
commandFor :: Stage -> BitVector 48
commandFor st = case st of
  GoIdle    -> frameFor 0  0x0000_0000
  IfCond    -> frameFor 8  0x0000_01AA  -- 2.7-3.6 V, and 0xAA to echo back
  AppCmd    -> frameFor 55 0x0000_0000
  OpCond    -> frameFor 41 0x4000_0000  -- bit 30: we understand high capacity
  ReadOcr   -> frameFor 58 0x0000_0000
  ReadBlock -> frameFor 17 0x0000_0000  -- block zero
  _         -> 0

-- | Initialise the card, read block zero, stop. Reset starts the whole sequence
-- again, so btnC is a retry button -- handy when the card was not in its socket
-- the first time.
sdCard
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ SPI half period in clock cycles minus one; see 'spiMaster'.
  -> Signal dom Bit
  -- ^ MISO.
  -> Signal dom SdOut
sdCard half miso = pins <$> spi <*> chipSelect <*> progress
 where
  spi = spiMaster half tx miso
  (tx, chipSelect, progress) = unbundle (mealy engine initial spi)

  pins sp sel p = SdOut
    { sdCs    = boolToBit (not sel)
    , sdSck   = spiSck sp
    , sdMosi  = spiMosi sp
    , sdStage = pStage p
    , sdFault = pFault p
    , sdR1    = pR1 p
    , sdExtra = pExtra p
    , sdData  = pData p
    }

  initial = Sd { stage    = PowerOn
               , failedAt = PowerOn
               , phase    = Priming primeBytes
               , frame    = 0
               , status   = 0xFF
               , extra    = 0
               , attempts = 0
               , awaiting = False
               , streamed = Nothing
               }

-- | One step of the sequencer. Bytes are handed to the master one at a time and
-- collected when they come back, so every transition below happens on a byte
-- boundary and the SPI timing stays entirely in "Protocol.SPI".
engine :: Sd -> SpiOut -> (Sd, (Maybe (BitVector 8), Bool, Progress))
engine s spi = (s', (offer, selected (phase s), progress))
 where
  -- Start a byte only when the bus is free and we are not already waiting for
  -- one. The cycle a transfer completes reports idle as well, so this also
  -- guarantees exactly one byte per response.
  offer
    | spiIdle spi, not (awaiting s) = case phase s of
        Halted    -> Nothing
        Sending _ -> Just (slice d47 d40 (frame s))
        _         -> Just 0xFF  -- MOSI must be high while the card talks
    | otherwise = Nothing

  s' | Just b <- spiRx spi = receive b s { awaiting = False, streamed = Nothing }
     | Just _ <- offer     = s { awaiting = True, streamed = Nothing }
     | otherwise           = s { streamed = Nothing }

  progress = Progress { pStage = stage s
                      , pFault = failedAt s
                      , pR1    = status s
                      , pExtra = extra s
                      , pData  = streamed s
                      }

-- | CS is asserted for everything except the power-on clocking, the byte that
-- releases the card after a command, and being done.
selected :: Phase -> Bool
selected p = case p of
  Priming _ -> False
  Releasing -> False
  Halted    -> False
  _         -> True

-- | A byte came back from the card. This is the whole protocol.
receive :: BitVector 8 -> Sd -> Sd
receive b s = case phase s of
  -- CS is already high, so the command can go straight out without the byte
  -- 'start' would otherwise insert. This is also where a retry begins, hence
  -- clearing what the last attempt learned.
  Priming n
    | n == 1    -> (start GoIdle s) { phase    = Sending 6
                                    , status   = 0xFF
                                    , extra    = 0
                                    , attempts = 0
                                    }
    | otherwise -> s { phase = Priming (n - 1) }

  -- The bytes shifted out of a command frame; what comes back is meaningless.
  Sending n
    | n == 1    -> shifted { phase = AwaitR1 maxPolls }
    | otherwise -> shifted { phase = Sending (n - 1) }
   where
    shifted = s { frame = shiftL (frame s) 8 }

  -- The card sends 0xFF until it answers, and R1's top bit is always clear.
  AwaitR1 t
    | not (testBit b 7) -> answered b s { status = b }
    | t == 0            -> giveUp s
    | otherwise         -> s { phase = AwaitR1 (t - 1) }

  AwaitTail n
    | n == 1    -> tailDone collected
    | otherwise -> collected { phase = AwaitTail (n - 1) }
   where
    collected = s { extra = shiftL (extra s) 8 .|. zeroExtend b }

  AwaitToken t
    | b == 0xFE -> s { phase = Receiving 0 }
    | b /= 0xFF -> giveUp s   -- an error token: the read will not happen
    | t == 0    -> giveUp s
    | otherwise -> s { phase = AwaitToken (t - 1) }

  -- 512 data bytes, then a 16-bit CRC we clock out and ignore.
  Receiving i
    | i == 513  -> start Ready s
    | otherwise -> s { phase    = Receiving (i + 1)
                     , streamed = if i < 512 then Just (i, b) else Nothing
                     }

  Releasing
    | stage s == Ready -> s { phase = Halted }
    | otherwise        -> s { phase = Sending 6 }

  Halted -> s

-- | Move on to @st@, first handing the bus back for one byte with CS high: eight
-- idle clocks are what let the card release MISO before the next command.
start :: Stage -> Sd -> Sd
start st s = s { stage = st, frame = commandFor st, phase = Releasing }

-- | Record where we gave up and start over. 'status' is deliberately left alone
-- so the R1 byte that caused the failure is still there to be read while 'stage'
-- is 'Failed'; the next attempt clears it.
giveUp :: Sd -> Sd
giveUp s = (start Failed s) { failedAt = stage s, phase = Priming primeBytes }

-- | The card answered R1. Whether that is good news depends on the stage, and
-- the stage decides what happens next. Anything unexpected -- an error bit, an
-- unsupported card -- falls through to 'giveUp'.
answered :: BitVector 8 -> Sd -> Sd
answered b s = case stage s of
  -- After CMD0 and CMD55 the card should be idle and otherwise unbothered.
  GoIdle    | idle                  -> start IfCond s
  AppCmd    | idle                  -> start OpCond s
  -- A version 1 card rejects CMD8 as illegal; we do not support those.
  IfCond    | not (testBit b 2)     -> s { phase = AwaitTail 4 }
  -- ACMD41 answers 0x01 while it is still working, 0x00 when initialised.
  OpCond    | b == 0x00             -> start ReadOcr s
            | b == 0x01
            , attempts s < maxTries -> (start AppCmd s) { attempts = attempts s + 1 }
  ReadOcr   | b == 0x00             -> s { phase = AwaitTail 4 }
  ReadBlock | b == 0x00             -> s { phase = AwaitToken maxWait }
  _                                 -> giveUp s
 where
  idle = b .&. complement 0x01 == 0

-- | The four extra bytes of an R3 or R7 arrived.
tailDone :: Sd -> Sd
tailDone s = case stage s of
  -- CMD8 echoes the check pattern back when it accepts the voltage range.
  IfCond | slice d15 d0 (extra s) == 0x01AA -> start AppCmd s
  -- The OCR is kept for the record; block zero needs no address arithmetic.
  ReadOcr                                   -> start ReadBlock s
  _                                         -> giveUp s

-- | Bytes clocked out with the card deselected before an attempt: 80 clocks,
-- comfortably over the 74 a card's power-on needs.
primeBytes :: Unsigned 4
primeBytes = 10

-- | The card is allowed eight bytes to answer (Ncr), but a cold CMD0 can take
-- longer, so be generous before calling it dead.
maxPolls :: Unsigned 8
maxPolls = 255

-- | ACMD41 may take a second. Each attempt is CMD55 plus ACMD41, about 18 bytes
-- or 360 us at 400 kHz, so this waits well over a second.
maxTries :: Unsigned 16
maxTries = 4000

-- | A card may take 100 ms to produce a block. 20000 bytes at 400 kHz is 400 ms.
maxWait :: Unsigned 16
maxWait = 20000
