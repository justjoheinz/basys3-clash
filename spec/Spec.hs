-- | The library's own checks: every claim in @src\/@ that can be made without a
-- design in scope, which turns out to be most of them. Runs in seconds and needs
-- no HDL simulator at all.
--
-- Two things this being a separate suite buys. It can be run on its own --
-- @stack test basys3@ -- so somebody bumping the snapshot can ask whether the
-- library still works without compiling anybody's designs. And because nothing
-- here may import a design, every check is written the way a user would write it:
-- a sequencer on a real transmitter, a controller against a pretend card, a format
-- compared against plain 'P.Integer' arithmetic. The @examples@ package's suite is
-- the other half, and it covers what the designs do with all of this.
module Main (main) where

import           Clash.Prelude
import           Control.Monad           (unless)
import           Data.Maybe              (mapMaybe)
import qualified Prelude                 as P
import           System.Exit             (exitFailure)

import           Ascii                   (ascii, dec, decDigits, hex, hexChar,
                                          hexNibble, line)
import           Basys3                  (baud115200, dwell, prescaler, settle,
                                          vBasys3)
import           Latch                   (latch)
import           Peripheral.Button       (bank, contact, falling)
import           Peripheral.SevenSegment (hexDigits, sevenSeg)
import           Pmod.FakeSdCard         (fakeCard, sectorByte)
import           Pmod.SdCard             (SdOut (..), Stage (..), frameFor, sdCard)
import           Protocol.SPI            (SpiOut (..), spiMaster)
import           Protocol.UART           (UartRx (..), UartTx (..), uartRx, uartTx)
import           Serial                  (Source, atReset, before, decoded, report,
                                          say, silent, transmit)

-- | How a value is spelt for a terminal: four hex digits most significant first,
-- then CR LF. The same composition the demos use, written here so the checks
-- below need nothing from a design.
--
-- The signature is what settles 'hex''s digit count -- @n@ is solved from the
-- result -- so nothing here needs a type application.
word :: BitVector 16 -> Vec 6 (BitVector 8)
word = line . hex

-- * The board's constants

-- | Seconds per clock cycle, taken from the domain rather than from the number
-- everybody knows: this is what makes the checks below tests rather than copies.
tick :: P.Double
tick = P.fromIntegral (vPeriod vBasys3) P.* 1e-12

-- | A duration as the cycle count "Peripheral.Button" and "Protocol.UART" want,
-- which is cycles minus one.
cyclesFor :: P.Double -> P.Integer
cyclesFor seconds = P.round (seconds P./ tick) P.- 1

-- * One-flip-flop circuits

-- | A single-cycle event, twenty cycles in, and nothing before or after it. What
-- 'latch' must do with it is answer 'False' until it arrives and 'True' for ever
-- after.
blip :: [Bool]
blip = P.replicate 20 False P.++ [True] P.++ P.repeat False

latchTrace :: [Bool]
latchTrace = sampleN 40
               (withClockResetEnable clockGen resetGen enableGen
                  (latch (fromList blip) :: Signal System Bool))

-- | The prescaler's pulses, as the cycles they land on.
tickAt :: [P.Int]
tickAt = [i | (i, t) <- P.zip [0 ..] pulses, t]
 where
  pulses = sampleN 24
             (withClockResetEnable clockGen resetGen enableGen
                (prescaler 2 :: Signal System Bool))

-- * Contacts

-- | A contact behaving the way a real one does: a couple of makes and breaks on
-- the way in, a press that lasts, more noise on release. With a settle time of
-- four cycles none of the single-cycle noise should survive the conditioning.
bouncy :: [Bit]
bouncy = P.concat
  [ P.replicate 4 low
  , [high, low, high, low]   -- bouncing on the way in
  , P.replicate 20 high      -- held down
  , [low, high, low]         -- and on the way out
  , P.replicate 20 low
  ]

-- | The steady level, the press pulse, and the release pulse.
contactProbe :: forall dom. HiddenClockResetEnable dom => Signal dom (Bool, Bool, Bool)
contactProbe = bundle (level, press, falling level)
 where
  (level, press) = contact 3 (fromList bouncy)

contactTrace :: [(Bool, Bool, Bool)]
contactTrace = sampleN (P.length bouncy)
                 (withClockResetEnable clockGen resetGen enableGen
                    (contactProbe :: Signal System (Bool, Bool, Bool)))

-- | A bank of switches that flickers before it settles: two of them thrown at
-- once, badly.
flicker :: [BitVector 16]
flicker = P.concat
  [ P.replicate 2 0
  , [0x00FF, 0x0FF0, 0x00FF, 0x0FF0]
  , P.replicate 20 0xBEEF
  ]

bankTrace :: [BitVector 16]
bankTrace = sampleN (P.length flicker)
              (withClockResetEnable clockGen resetGen enableGen
                 (bank 3 (fromList flicker) :: Signal System (BitVector 16)))

-- * The UART

-- | One 8N1 frame as the host's end of the wire would drive it, @width@ cycles a
-- bit: a low start bit, eight data bits least significant first, then whatever
-- stop level is wanted. Built by hand rather than with 'uartTx', so a receiver
-- test does not rest on the transmitter being right.
frame :: P.Int -> Bit -> BitVector 8 -> [Bit]
frame width stop b = P.concatMap (P.replicate width)
  (low : [if testBit b k then high else low | k <- [0 .. 7]] P.++ [stop])

-- | 0x5A at four cycles a bit, written out rather than computed: a start bit,
-- then 0 1 0 1 1 0 1 0 -- least significant first, which is exactly where UART
-- and this project's SPI differ -- then a stop bit.
expectedFrame :: [Bit]
expectedFrame = P.concatMap (P.replicate 4)
  [low, low, high, low, high, high, low, high, low, high]

-- | Found by where the line first leaves the mark level rather than by counting
-- cycles from reset, so it does not depend on how long reset is held.
txSent :: [Bit]
txSent = P.dropWhile (== high) (sampleN 80 wire)
 where
  wire = withClockResetEnable clockGen resetGen enableGen
           (txLine <$> uartTx 3 offered :: Signal System Bit)
  offered = fromList ([Nothing, Nothing, Just 0x5A] P.++ P.repeat Nothing)

-- | The transmitter's own line into the receiver at eight cycles a bit, with a
-- new byte offered the moment the transmitter will take one, so frames run back
-- to back with no idle gap -- the tightest resynchronisation the receiver ever
-- faces. Every byte should come back out, which only holds if the sample points
-- land in the middle of the bits the transmitter drove.
uartLoop :: forall dom. HiddenClockResetEnable dom => Signal dom UartRx
uartLoop = uartRx 7 (txLine <$> tx)
 where
  tx    = uartTx 7 offer
  offer = mux (txIdle <$> tx) (Just <$> next) (pure Nothing)
  next  = regEn 0 (txIdle <$> tx) ((+ 0x33) <$> next)

uartLoopTrace :: [UartRx]
uartLoopTrace = sampleN 900
                  (withClockResetEnable clockGen resetGen enableGen
                     (uartLoop :: Signal System UartRx))

-- | Noise on an idle line: a one-cycle dip and a three-cycle one, both shorter
-- than the half bit period at which the receiver re-checks a candidate start
-- bit. Neither should produce a byte or an error.
glitches :: [Bit]
glitches = P.concat
  [ P.replicate 10 high, [low]
  , P.replicate 40 high, P.replicate 3 low
  , P.replicate 150 high
  ]

glitchTrace :: [UartRx]
glitchTrace = sampleN (P.length glitches)
                (withClockResetEnable clockGen resetGen enableGen
                   (uartRx 7 (fromList glitches) :: Signal System UartRx))

-- | A frame whose stop bit is low, then a good one. The bad frame must report a
-- framing error and no byte; the good one must still arrive, which is the claim
-- the receiver's recovery phase exists to make -- without it a break, or a reset
-- in the middle of somebody else's frame, reads as a stream of zero bytes.
badThenGood :: [Bit]
badThenGood = P.concat
  [ P.replicate 16 high
  , frame 8 low 0x41
  , P.replicate 24 high
  , frame 8 high 0x42
  , P.replicate 100 high
  ]

framingTrace :: [UartRx]
framingTrace = sampleN (P.length badThenGood)
                 (withClockResetEnable clockGen resetGen enableGen
                    (uartRx 7 (fromList badThenGood) :: Signal System UartRx))

-- | What 'decoded' is handed: a cycle with nothing on it, a byte that means
-- something, a byte that does not, and a cycle carrying a framing error instead
-- of a byte. 'hexNibble' stands in for a design's own vocabulary.
arriving :: [UartRx]
arriving =
  [ UartRx Nothing        False
  , UartRx (Just 0x41)    False   -- 'A', a hex digit
  , UartRx (Just 0x20)    False   -- a space, which means nothing here
  , UartRx Nothing        True    -- a framing error, and no byte with it
  ]

-- * Talking to the host

-- | 'say' driving a real transmitter into a real receiver, so what comes out is
-- what a terminal would see. The trigger is held high for the first hundred
-- cycles and then dropped: three bytes take 240 cycles at this divisor, so the
-- trigger is still asserted well into the string. A 'say' that took it twice
-- would stutter its first letter, and one that took it on every cycle would
-- never get past it.
sayLoop :: forall dom. HiddenClockResetEnable dom => Signal dom (UartRx, Bool)
sayLoop = bundle (uartRx 7 (txLine <$> tx), busy)
 where
  tx = uartTx 7 offer
  (offer, busy) = say $(ascii "Hi!") trigger (txIdle <$> tx)
  trigger = fromList (P.replicate 100 True P.++ P.repeat False)

sayTrace :: [(UartRx, Bool)]
sayTrace = sampleN 600
             (withClockResetEnable clockGen resetGen enableGen
                (sayLoop :: Signal System (UartRx, Bool)))

-- | A 'Source' on its own transmitter with a receiver listening to the line, so
-- what a test asserts is the bytes a terminal would see rather than where in a
-- trace they ought to be. Rank-2 so the source is written once and instantiated
-- here at 'System'.
spoke
  :: P.Int
  -> (forall dom. HiddenClockResetEnable dom => Source dom)
  -> [BitVector 8]
spoke cycles src = mapMaybe rxByte (sampleN cycles heard)
 where
  heard = withClockResetEnable clockGen resetGen enableGen
            (uartRx 7 (transmit 7 src) :: Signal System UartRx)

-- | A value that moves while it is being reported. One report is six bytes at
-- 81 cycles each, so: 0x0000 is still current when the first report starts and
-- has gone by the tenth cycle of it, and all three of the later values land
-- inside the report of 0x1234. The host should hear 0x0000 undisturbed, then
-- 0x1234, then one report of 0x0009 -- not one per change.
moving :: [BitVector 16]
moving = P.concat
  [ P.replicate 10 0x0000
  , P.replicate 490 0x1234
  , P.replicate 20 0x0005
  , P.replicate 20 0x0007
  , P.repeat 0x0009
  ]

reportSaid :: [BitVector 8]
reportSaid = spoke 1700 (report word (fromList moving))

-- | A report as the host should see it: four hex characters most significant
-- first, then CR LF. Spelt by another route than 'word' -- 'hexDigits' and a
-- 'P.reverse' -- so the report checks do not compare 'hex' against itself.
said :: BitVector 16 -> [BitVector 8]
said v = P.map hexChar (P.reverse (toList (hexDigits v))) P.++ [0x0D, 0x0A]

-- | "Hi!", the string the 'before' and 'silent' checks hand over.
hi :: [BitVector 8]
hi = [0x48, 0x69, 0x21]

-- * Base ten

-- | An 'P.Int' as the 16 bits the decimal checks below convert. Named because
-- 'decDigits' takes any input width and nothing in a literal decides which, so
-- every use would otherwise carry the same annotation.
bits16 :: P.Int -> BitVector 16
bits16 = P.fromIntegral

-- | The five decimal digits of @n@ the way 'decDigits' should give them: most
-- significant first. Division and 'P.mod' in plain 'P.Int', so nothing about the
-- double dabble is assumed.
decRef :: P.Int -> [Unsigned 4]
decRef n = [P.fromIntegral (n `P.div` p `P.mod` 10) | p <- [10000, 1000, 100, 10, 1]]

-- | 'dec' as a 'P.String', so a mismatch reads as the number it should have been
-- rather than as five byte values.
spelt :: P.Int -> P.String
spelt n = P.map (P.toEnum . P.fromIntegral)
            (toList (dec (bits16 n) :: Vec 5 (BitVector 8)))

-- * SPI and the card

-- | MISO tied to MOSI: every byte sent should come straight back. That only
-- holds if the master shifts out and samples in on the edges it claims to, so it
-- is a cheap check on the bit-level timing.
spiLoopback :: HiddenClockResetEnable dom => Signal dom SpiOut
spiLoopback = out
 where
  out = spiMaster 1 tx (spiMosi <$> out)
  tx  = (\o -> if spiIdle o then Just 0x5A else Nothing) <$> out

spiEchoes :: [BitVector 8]
spiEchoes = mapMaybe spiRx trace
 where
  trace = sampleN 200
            (withClockResetEnable clockGen resetGen enableGen
               (spiLoopback :: Signal System SpiOut))

-- | The controller and the pretend card, connected by nothing but the four SPI
-- wires. This is the real test: a full initialisation sequence and a block read,
-- bit by bit, in a couple of seconds of simulation.
sdBus :: HiddenClockResetEnable dom => Signal dom SdOut
sdBus = out
 where
  out  = sdCard 1 miso
  miso = fakeCard (bundle (sdCs <$> out, sdSck <$> out, sdMosi <$> out))

-- | Long enough for the whole sequence: roughly 630 bytes at 33 cycles each,
-- most of them the 512-byte block.
sdTrace :: [SdOut]
sdTrace = sampleN 30_000 (withClockResetEnable clockGen resetGen enableGen (sdBus :: Signal System SdOut))

-- | The block, as it was streamed out with its byte indices.
sdBlock :: [(Unsigned 10, BitVector 8)]
sdBlock = mapMaybe sdData sdTrace

-- | Nothing on the bus at all: MISO tied high, as an empty socket reads through
-- the Pmod's pull-up. Every poll times out, so this is the retry path.
deadTrace :: [SdOut]
deadTrace = sampleN 40_000
              (withClockResetEnable clockGen resetGen enableGen
                 (sdCard 1 (pure high) :: Signal System SdOut))

-- | How many times an attempt was abandoned and another one started.
restarts :: P.Int
restarts = P.length
  [() | (a, b) <- P.zip deadTrace (P.drop 1 deadTrace)
      , sdStage a == Failed, sdStage b /= Failed]

check :: (P.Eq a, P.Show a) => P.String -> [a] -> [a] -> P.IO Bool
check name expected actual
  | actual P.== expected = do
      P.putStrLn ("basys3: " P.++ name P.++ " matches")
      P.pure True
  | P.otherwise = do
      P.putStrLn ("basys3: " P.++ name P.++ " MISMATCH")
      P.putStrLn ("  expected: " P.++ P.show expected)
      P.putStrLn ("  actual:   " P.++ P.show actual)
      P.pure False

main :: P.IO ()
main = do
  -- The board's numbers against the board's clock. Nothing else ties them
  -- together: 'settle' and the rest are literals, and this is what would notice
  -- if the domain's period changed and they did not.
  timingOk <- check "the board's cycle counts are what its 100 MHz clock makes them"
                [(cyclesFor 5e-3, cyclesFor 1e-3, cyclesFor (1 P./ 115200))]
                [(toInteger settle, toInteger dwell, toInteger baud115200)]
  tickOk   <- check "the prescaler pulses once every limit + 1 cycles"
                [[3, 3, 3, 3]]
                [P.take 4 (P.zipWith (P.-) (P.drop 1 tickAt) tickAt)]

  -- One-cycle events are what hardware reports and what nobody can see, so
  -- 'latch' is the difference between a lamp and a coin toss.
  latchOk  <- check "latch is false until its event and true ever after"
                [(False, True, True)]
                [( P.or (P.take 20 latchTrace)
                 , latchTrace P.!! 22
                 , P.last latchTrace )]

  -- Active-low cathodes: "8" lights everything (0x00), "0" leaves only the
  -- middle bar dark (0x40), "1" lights just the two right-hand bars (0x79).
  segOk   <- check "seven-segment patterns"
               [0x40, 0x79, 0x24, 0x30, 0x19, 0x12, 0x02, 0x78, 0x00, 0x10]
               (P.map sevenSeg [0 .. 9])
  hexOk   <- check "seven-segment hex digits"
               [0x08, 0x03, 0x46, 0x21, 0x06, 0x0E]
               (P.map sevenSeg [10 .. 15])
  -- Index 0 is the rightmost digit, so 0x55AA reads as 55AA on the board.
  splitOk <- check "a word splits into hex digits, least significant first"
               [0xA, 0xA, 0x5, 0x5] (toList (hexDigits (0x55AA :: BitVector 16)))

  -- Contacts bounce, and a design that counts edges has to see one press per
  -- press. The release pulse is the same claim in the other direction.
  pressOk <- check "a bouncing contact reads as one press and one release"
               [(1, 1) :: (P.Int, P.Int)]
               [( P.length [() | (_, p, _) <- contactTrace, p]
                , P.length [() | (_, _, r) <- contactTrace, r] )]
  quietOk <- check "no bounce reaches the output before the contact settles"
               [False] [P.or [l | (l, _, _) <- P.take 12 contactTrace]]
  -- Switches share one counter, so the bank moves as a unit: nothing until every
  -- bit has held still, then the new reading all at once.
  bankOk  <- check "a bank of switches updates only once it holds still"
               [(True, 0xBEEF)]
               [(P.all (P.== 0) (P.take 10 bankTrace), P.last bankTrace)]

  -- The UART, both halves. The frame shape is the claim worth spelling out: the
  -- data bits go least significant first, the other way round from SPI.
  frameOk <- check "a transmitted byte is a start bit, eight bits LSB first, a stop bit"
               expectedFrame (P.take 40 txSent)
  markOk  <- check "and the line returns to mark with the stop bit at full width"
               (P.replicate 8 high) (P.take 8 (P.drop 40 txSent))
  -- 0x00 is every data bit low, which is what stresses the stop bit; 0xFF is
  -- every one high, which is what stresses finding the start bit.
  loopOk  <- check "back-to-back frames all survive the round trip"
               [0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF]
               (P.take 6 (mapMaybe rxByte uartLoopTrace))
  cleanOk <- check "and none of them is reported as a framing error"
               [False] [P.any rxError uartLoopTrace]
  noiseOk <- check "a dip too short to be a start bit is ignored"
               [(0, False)]
               [( P.length (mapMaybe rxByte glitchTrace)
                , P.any rxError glitchTrace )]
  breakOk <- check "a low stop bit reports one error, no byte, and does not wedge"
               [(1 :: P.Int, [0x42])]
               [( P.length [() | r <- framingTrace, rxError r]
                , mapMaybe rxByte framingTrace )]
  -- A byte that means nothing and no byte at all have to look the same, because
  -- the same thing is done about them: nothing.
  askedOk <- check "decoded gives a meaning only for a byte that has one"
               [[Nothing, Just 10, Nothing, Nothing]]
               [ sampleN 4 (decoded hexNibble (fromList arriving)
                              :: Signal System (Maybe (Unsigned 4))) ]

  charOk  <- check "nibbles map to ASCII hex, upper case"
               [0x30, 0x31, 0x39, 0x41, 0x46] (P.map hexChar [0, 1, 9, 10, 15])
  nibOk   <- check "ASCII hex maps back, either case, and nothing else does"
               [Just 0, Just 9, Just 10, Just 15, Just 10, Just 15, Nothing, Nothing, Nothing]
               (P.map hexNibble [0x30, 0x39, 0x41, 0x46, 0x61, 0x66, 0x47, 0x20, 0x0D])
  spellOk <- check "hex spells a word most significant first, and line ends it"
               [0x30, 0x42, 0x45, 0x46, 0x0D, 0x0A] (toList (word 0x0BEF))

  -- Base ten is the one conversion in "Ascii" that is not a 'bitCoerce', so it is
  -- the one that can be wrong. Named values first, for a readable failure.
  digitsOk <- check "double dabble gives the decimal digits, most significant first"
                (P.map decRef [0, 9, 10, 42, 999, 1000, 12345, 65535])
                [ toList (decDigits (bits16 n) :: Vec 5 (Unsigned 4))
                | n <- [0, 9, 10, 42, 999, 1000, 12345, 65535 :: P.Int] ]
  -- Then every 16-bit value there is, which is what actually rules out a carry
  -- that only goes wrong at one boundary. 65536 conversions, well under a second.
  allDecOk <- check "and does so for all 65536 of them" [True]
                [ P.and [ toList (decDigits (bits16 n) :: Vec 5 (Unsigned 4))
                            P.== decRef n
                        | n <- [0 .. 65535 :: P.Int] ] ]
  -- Too few digits truncates rather than saturating or wrapping oddly, which is
  -- what 'decDigits' promises and the only way a caller can get it wrong.
  narrowOk <- check "too few digits keeps the least significant ones"
                [[2, 3, 4, 5]]
                [toList (decDigits (12345 :: BitVector 16) :: Vec 4 (Unsigned 4))]
  -- Leading zeros blanked, but never the last digit: zero has to read as "0".
  decOk    <- check "dec blanks leading zeros, right aligned, and zero is one digit"
                ["    0", "    9", "   10", "   42", "  999", " 1000", "12345", "65535"]
                (P.map spelt [0, 9, 10, 42, 999, 1000, 12345, 65535])

  -- The whole string, in order and once, though the trigger is held across the
  -- first bytes of it -- so a held button says a thing once rather than stuttering
  -- its first letter. 'busy' must have fallen by the end, or nothing downstream
  -- could ever tell that the transmitter is free again.
  sayOk   <- check "say hands a whole string to the transmitter, once"
               hi (mapMaybe (rxByte . P.fst) sayTrace)
  doneOk  <- check "and stops claiming the transmitter when it runs out of string"
               [(True, False)]
               [(P.any P.snd sayTrace, P.snd (P.last sayTrace))]

  -- The writing path, on its own transmitter and read back off the wire.
  freezeOk <- check "a report describes one value even though the value moves inside it"
                (said 0x0000) (P.take 6 reportSaid)
  mergeOk <- check "and changes during a report coalesce into exactly one more report"
               (P.concatMap said [0x0000, 0x1234, 0x0009]) reportSaid
  -- The predecessor of 'report' started from "the host was told maxBound", which
  -- meant a value that happened to sit at 0xFFFF out of reset was never reported.
  -- Starting from "the host has been told nothing" is what makes this hold for
  -- every value rather than all but one.
  firstOk <- check "a value is reported once out of reset, 0xFFFF included"
               (said 0xFFFF) (spoke 600 (report word (pure 0xFFFF)))
  -- The reporter wants to talk from the first cycle, so the greeting can only get
  -- out first if 'before' makes it -- and the report can only be intact if being
  -- held off loses nothing.
  orderOk <- check "before lets the left source go first and the right one loses nothing"
               (hi P.++ said 0x0042)
               (spoke 900 (say $(ascii "Hi!") atReset `before` report word (pure 0x0042)))
  quietSrcOk <- check "silent is the identity for before, on either side"
               [hi, hi]
               [ spoke 400 (silent `before` say $(ascii "Hi!") atReset)
               , spoke 400 (say $(ascii "Hi!") atReset `before` silent) ]

  -- CMD0 and CMD8 are the two commands whose CRC a card actually checks, and
  -- both frames are documented constants -- 0x95 and 0x87 -- so they pin down
  -- the CRC7 implementation exactly.
  crcOk   <- check "CMD0 and CMD8 frames carry the CRC7 the spec fixes"
               [0x4000_0000_0095, 0x4800_0001_AA87]
               [frameFor 0 0x0000_0000, frameFor 8 0x0000_01AA]

  echoOk  <- check "SPI loopback returns what was sent"
               (P.replicate 6 0x5A) (P.take 6 spiEchoes)

  -- The end state, which is the whole point: initialised, and a block read.
  readyOk <- check "the card initialises and block zero is read"
               [Ready] [sdStage (P.last sdTrace)]
  -- On failure this names the stage that gave up, which is the first thing worth
  -- knowing.
  failOk  <- check "no stage gives up along the way"
               [] (P.take 1 [sdFault o | o <- sdTrace, sdStage o == Failed])
  ocrOk   <- check "CMD58 reports a powered-up, high-capacity card"
               [0xC0FF_8000] [sdExtra (P.last sdTrace)]
  idxOk   <- check "the block arrives in order, 512 bytes of it"
               [0 .. 511] (P.map P.fst sdBlock)
  dataOk  <- check "the block is what the card had" [True]
               [P.map P.snd sdBlock P.== P.map sectorByte [0 .. 511]]
  sigOk   <- check "the block ends in the 0x55AA signature"
               [0x55, 0xAA] (P.drop 510 (P.map P.snd sdBlock))

  -- An empty socket: CMD0 is where it gives up, with no response byte to show
  -- for it -- which is the F1FF the display reads when no card is in.
  deadOk  <- check "an unanswered bus gives up at CMD0 with no status byte"
               [(GoIdle, 0xFF)]
               (P.take 1 [(sdFault o, sdR1 o) | o <- deadTrace, sdStage o == Failed])
  -- And does not stay given up: a card inserted later must be picked up.
  retryOk <- check "giving up starts another attempt" [True] [restarts P.>= 2]

  unless (P.and [ timingOk, tickOk, latchOk
                , segOk, hexOk, splitOk
                , pressOk, quietOk, bankOk
                , frameOk, markOk, loopOk, cleanOk, noiseOk, breakOk, askedOk
                , charOk, nibOk, spellOk
                , digitsOk, allDecOk, narrowOk, decOk
                , sayOk, doneOk, freezeOk, mergeOk, firstOk, orderOk, quietSrcOk
                , crcOk, echoOk, readyOk, failOk, ocrOk, idxOk, dataOk, sigOk
                , deadOk, retryOk
                ]) exitFailure
