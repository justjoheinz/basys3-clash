-- | Haskell-level simulation of the designs. Runs in seconds and needs no HDL
-- simulator at all: @stack test@.
module Main (main) where

import           Clash.Prelude
import           Control.Monad (unless)
import           Data.Maybe    (fromMaybe, listToMaybe, mapMaybe)
import qualified Prelude       as P
import           System.Exit   (exitFailure)

-- 'hex' and 'line' are not imported: 'IoDemo.word' is their composition, and
-- 'spellOk' pins its bytes -- which no reordering of either could survive.
import           Ascii                     (ascii, hexChar, hexNibble)
import           Blinky                    (Digits, bcdSucc, blinky, prescaler,
                                            rotator)
import           IoDemo                    (Typed (..), greeting, ioDemo, typedAs,
                                            word)
import           Peripheral.Button         (bank, contact, falling)
import           Peripheral.SevenSegment   (hexDigits, sevenSeg)
import           Pmod.FakeSdCard           (fakeCard, sectorByte)
import           Pmod.SdCard               (SdOut (..), Stage (..), frameFor,
                                            sdCard)
import           Protocol.SPI              (SpiOut (..), spiMaster)
import           Protocol.UART             (UartRx (..), UartTx (..), uartRx,
                                            uartTx)
import           SdDemo                    (sdDemo)
import           Serial                    (Source, atReset, before, report, say,
                                            silent, transmit)

-- | What 'Blinky.topEntity' drives: LEDs, cathodes, digit enables, decimal
-- point.
type Out = (BitVector 16, BitVector 7, BitVector 4, Bit)

-- | With a blink limit of 2 each half of the blink lasts three cycles, and a
-- dwell of 100 parks the scan on digit 0 (@an = 1110@) for the whole run. The
-- count steps as the LEDs come on, so the ones digit reads 0, 1, then 2.
expectedBlink :: [Out]
expectedBlink =
  P.concatMap (P.replicate 3)
    [ (0x0000, 0x40, 0xE, high)  -- dark, "0"
    , (0xFFFF, 0x79, 0xE, high)  -- lit,  "1"
    , (0x0000, 0x79, 0xE, high)  -- dark, "1"
    , (0xFFFF, 0x24, 0xE, high)  -- lit,  "2"
    ]

-- | 'rotator' is not wired into 'blinky', so check it on its own: the one-hot
-- pattern walks 1 -> 2 -> 4 -> 8.
expectedWalk :: [BitVector 16]
expectedWalk = [1, 1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8]

-- | The first sample is taken while reset is still asserted, so drop it.
postReset :: NFDataX a => P.Int -> Signal System a -> [a]
postReset n s = P.drop 1 (sampleN (1 P.+ n) s)

simulatedBlink :: [Out]
simulatedBlink = postReset (P.length expectedBlink) out
 where
  out = withClockResetEnable clockGen resetGen enableGen (blinky 2 100)

simulatedWalk :: [BitVector 16]
simulatedWalk = postReset (P.length expectedWalk) leds
 where
  leds = withClockResetEnable clockGen resetGen enableGen (rotator (prescaler 2))

-- | The four decimal digits of @n@, least significant first -- the reference
-- 'bcdSucc' is checked against.
bcd :: P.Int -> Digits
bcd n = map (\p -> P.fromIntegral (n `P.div` p `P.mod` 10)) (1 :> 10 :> 100 :> 1000 :> Nil)

-- | Carries worth naming, including the 9999 -> 0000 wrap.
carries :: [(P.Int, P.Int)]
carries = [(0, 1), (8, 9), (9, 10), (98, 99), (99, 100), (999, 1000), (9998, 9999), (9999, 0)]

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
  -- Annotated for the same reason as 'demoBus' below: a tuple pattern binding
  -- under MonoLocalBinds would otherwise be inferred in a domain of its own.
  conditioned :: (Signal dom Bool, Signal dom Bool)
  conditioned    = contact 3 (fromList bouncy)
  (level, press) = conditioned

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

-- | One clean press starting at cycle @from@ and held for 15 cycles: long
-- enough to survive 'ioDemo''s debouncing, short enough to finish before the
-- next one. Infinite, so 'fromList' never runs out.
held :: P.Int -> [Bit]
held from = [if i >= from && i P.< from P.+ 15 then high else low | i <- [0 ..]]

-- | What 'IoDemo.topEntity' drives: the same four as 'Blinky', and its transmit
-- pin.
type IoOut = (BitVector 16, BitVector 7, BitVector 4, Bit, Bit)

ioLeds :: IoOut -> BitVector 16
ioLeds (l, _, _, _, _) = l

ioScan :: IoOut -> (BitVector 7, BitVector 4)
ioScan (_, s, a, _, _) = (s, a)

-- | The decimal point, which this design uses as its framing-error light. Active
-- low, so 'low' is lit.
ioPoint :: IoOut -> Bit
ioPoint (_, _, _, p, _) = p

ioTx :: IoOut -> Bit
ioTx (_, _, _, _, t) = t

-- | The switch-and-button design, driven through all four of its buttons in
-- turn with the switches held at 0x00A5: up, then load, then down, then clear.
-- A settle of four cycles and a dwell of five keep the whole run to 300 cycles.
-- Nothing arrives from the host, so the transmit side is ignored here.
ioTrace :: [IoOut]
ioTrace = sampleN 300
            (withClockResetEnable clockGen resetGen enableGen
               (ioDemo 3 4 7 (pure 0x00A5)
                  (fromList (held 10))   -- btnU, up
                  (fromList (held 150))  -- btnD, down
                  (fromList (held 220))  -- btnL, clear
                  (fromList (held 80))   -- btnR, load
                  (pure high)            -- uart_rx, idle
                  :: Signal System IoOut))

-- | What the display reads over a window of the trace: with a dwell of five the
-- scan visits all four digits in 20 cycles, so one of each is always in a window
-- of 30. Position 0 is the rightmost digit.
digitsOf :: [IoOut] -> [BitVector 7]
digitsOf visible = [digitAt scan d | d <- [0 .. 3]]
 where
  scan = P.map ioScan visible

-- | The segment pattern a scan shows for one digit position. 0x00 if the window
-- never selected it, which no real digit is -- the cathodes are active low, so
-- 0x00 lights every segment at once. That way a window too short to see all four
-- digits fails the comparison it feeds instead of throwing from a partial 'head',
-- and the failure names the digit that went missing.
digitAt :: [(BitVector 7, BitVector 4)] -> P.Int -> BitVector 7
digitAt scan d = fromMaybe 0 (listToMaybe [s | (s, a) <- scan, a == complement (bit d)])

ioDigits :: P.Int -> [BitVector 7]
ioDigits from = digitsOf (P.take 30 (P.drop from ioTrace))

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
txSent = P.dropWhile (== high) (sampleN 80 line)
 where
  line = withClockResetEnable clockGen resetGen enableGen
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
  -- Annotated for the reason 'demoBus' below is: the feedback loop would
  -- otherwise be inferred in a domain of its own under MonoLocalBinds.
  tx :: Signal dom UartTx
  tx    = uartTx 7 offer
  offer = mux (txIdle <$> tx) (Just <$> next) (pure Nothing)
  next  = regEn 0 (txIdle <$> tx) ((+ 0x33) <$> next)

uartLoopTrace :: [UartRx]
uartLoopTrace = sampleN 900
                  (withClockResetEnable clockGen resetGen enableGen
                     (uartLoop :: Signal System UartRx))

-- | 'say' driving a real transmitter into a real receiver, so what comes out is
-- what a terminal would see. The trigger is held high for the first hundred
-- cycles and then dropped: three bytes take 240 cycles at this divisor, so the
-- trigger is still asserted well into the string. A 'say' that took it twice
-- would stutter its first letter, and one that took it on every cycle would
-- never get past it.
sayLoop :: forall dom. HiddenClockResetEnable dom => Signal dom (UartRx, Bool)
sayLoop = bundle (uartRx 7 (txLine <$> tx), busy)
 where
  -- Annotated for the reason 'uartLoop' above is.
  tx :: Signal dom UartTx
  tx = uartTx 7 offer
  (offer, busy) = say $(ascii "Hi!") trigger (txIdle <$> tx)
  trigger = fromList (P.replicate 100 True P.++ P.repeat False)

sayTrace :: [(UartRx, Bool)]
sayTrace = sampleN 600
             (withClockResetEnable clockGen resetGen enableGen
                (sayLoop :: Signal System (UartRx, Bool)))

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

-- | What 'SdDemo.topEntity' drives: the three SPI pins it owns, then the same
-- LEDs, cathodes, digit enables and decimal point as 'Blinky'.
type DemoOut = (Bit, Bit, Bit, BitVector 16, BitVector 7, BitVector 4, Bit)

demoLeds :: DemoOut -> BitVector 16
demoLeds (_, _, _, l, _, _, _) = l

demoScan :: DemoOut -> (BitVector 7, BitVector 4)
demoScan (_, _, _, _, s, a, _) = (s, a)

-- | The board design driving the pretend card, with both switches reading low.
demoBus :: forall dom. HiddenClockResetEnable dom => Signal dom DemoOut
demoBus = out
 where
  -- The annotation is what ties the feedback loop below to this signature's
  -- domain: the tuple pattern would otherwise be inferred in one of its own.
  out :: Signal dom DemoOut
  out  = sdDemo 1 100 miso (pure low) (pure low)
  miso = fakeCard (bundle (cs, sck, mosi))
  (cs, sck, mosi, _, _, _, _) = unbundle out

demoTrace :: [DemoOut]
demoTrace = sampleN 40_000
              (withClockResetEnable clockGen resetGen enableGen
                 (demoBus :: Signal System DemoOut))

-- | What each digit position is displaying once the read has finished, taken
-- from the last thousand cycles: more than the four dwells of 101 cycles the
-- scan needs to visit every digit. Position 0 is the rightmost.
demoDigits :: [BitVector 7]
demoDigits = [digitAt scan d | d <- [0 .. 3]]
 where
  scan = P.map demoScan (P.drop 39_000 demoTrace)

-- | A report as the host should see it: four hex characters most significant
-- first, then CR LF. 'hexChar' is checked on its own, so using it here buys
-- readability without begging the question.
said :: BitVector 16 -> [BitVector 8]
said v = P.map hexChar (P.reverse (toList (hexDigits v))) P.++ [0x0D, 0x0A]

-- | The greeting as the host should see it. Taken from the design rather than
-- typed out again: it is prose and it will be reworded, and rewording it once
-- already broke two traces that had nothing to do with what it says.
greeted :: [BitVector 8]
greeted = toList greeting

-- | Cycles one byte takes at divisor 7: ten bits on the wire, eight cycles each.
byteTime :: P.Int
byteTime = 80

-- | How long the host must keep quiet: the whole greeting, the one report the
-- reset causes -- six bytes -- and a byte of slack. A character landing inside
-- that would arrive mid-report and the reports would coalesce, which is correct
-- behaviour but not what these traces are checking.
leadIn :: P.Int
leadIn = byteTime * (P.length greeted + 6 + 1)

-- | Silence after each character, wide enough for the report it causes to finish,
-- so the expected output stays a plain list.
gap :: P.Int
gap = byteTime * 8

-- | A host that keeps quiet through 'leadIn' and then types, waiting 'gap' after
-- each character.
hostTyping :: [BitVector 8] -> [Bit]
hostTyping cs =
  P.replicate leadIn high
    P.++ P.concatMap (\c -> frame 8 high c P.++ P.replicate gap high) cs
    P.++ P.repeat high

-- | Cycles to sample for a host that types that many characters: the lead-in,
-- every character and its gap, and room for the last report to drain.
watching :: P.Int -> P.Int
watching chars = leadIn + chars * (byteTime + gap) + byteTime * 7

-- | The design with a receiver on its own transmit line, which is how to assert
-- what it said without counting cycles to where the bytes ought to be. The host
-- types @beef@ in lower case; no button is pressed, so every report but the first
-- is one the host caused.
hostDemo :: forall dom. HiddenClockResetEnable dom => Signal dom (IoOut, UartRx)
hostDemo = bundle (out, uartRx 7 (ioTx <$> out))
 where
  -- Annotated for the reason 'demoBus' is: the tuple above would otherwise be
  -- inferred in a domain of its own.
  out :: Signal dom IoOut
  out = ioDemo 3 4 7 (pure 0x00A5) (pure low) (pure low) (pure low) (pure low)
          (fromList (hostTyping [0x62, 0x65, 0x65, 0x66]))

hostTrace :: [(IoOut, UartRx)]
hostTrace = sampleN (watching 4)
              (withClockResetEnable clockGen resetGen enableGen
                 (hostDemo :: Signal System (IoOut, UartRx)))

-- | The same arrangement, with the host pressing @k@ twice and @j@ once instead of
-- typing a value. Separate from 'hostDemo' rather than appended to it so that each
-- trace asserts one thing: this one is that a keystroke steps the counter by
-- exactly one, in the direction asked for, and that the host hears about each
-- step.
stepDemo :: forall dom. HiddenClockResetEnable dom => Signal dom (IoOut, UartRx)
stepDemo = bundle (out, uartRx 7 (ioTx <$> out))
 where
  -- Annotated for the reason 'hostDemo' is.
  out :: Signal dom IoOut
  out = ioDemo 3 4 7 (pure 0x00A5) (pure low) (pure low) (pure low) (pure low)
          (fromList (hostTyping [0x6B, 0x4B, 0x6A]))   -- 'k', 'K', 'j'

stepTrace :: [(IoOut, UartRx)]
stepTrace = sampleN (watching 3)
              (withClockResetEnable clockGen resetGen enableGen
                 (stepDemo :: Signal System (IoOut, UartRx)))

-- | One frame with its stop bit low, which is what a terminal at the wrong speed
-- looks like from this end. The decimal point should light and stay lit.
faultTrace :: [IoOut]
faultTrace = sampleN 400
               (withClockResetEnable clockGen resetGen enableGen
                  (ioDemo 3 4 7 (pure 0) (pure low) (pure low) (pure low) (pure low)
                     (fromList (P.replicate 16 high
                                  P.++ frame 8 low 0x41
                                  P.++ P.repeat high))
                   :: Signal System IoOut))

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

-- | "Hi!", the string the 'before' and 'silent' checks hand over.
hi :: [BitVector 8]
hi = [0x48, 0x69, 0x21]

check :: (P.Eq a, P.Show a) => P.String -> [a] -> [a] -> P.IO Bool
check name expected actual
  | actual P.== expected = do
      P.putStrLn ("blinky: " P.++ name P.++ " matches")
      P.pure True
  | P.otherwise = do
      P.putStrLn ("blinky: " P.++ name P.++ " MISMATCH")
      P.putStrLn ("  expected: " P.++ P.show expected)
      P.putStrLn ("  actual:   " P.++ P.show actual)
      P.pure False

main :: P.IO ()
main = do
  blinkOk <- check "blink and display" expectedBlink simulatedBlink
  walkOk  <- check "one-hot walk"      expectedWalk  simulatedWalk
  carryOk <- check "BCD carries, including the wrap"
               (P.map (bcd . P.snd) carries)
               (P.map (bcdSucc . bcd . P.fst) carries)
  -- The whole "modulo 10000" claim, over every value rather than a sample.
  wrapOk  <- check "BCD counts decimally for all 10000 values" [True]
               [P.all (\n -> bcdSucc (bcd n) == bcd ((n P.+ 1) `P.mod` 10000)) [0 .. 9999]]
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

  -- The switch-and-button design. One press is one step, which is the claim the
  -- debouncing exists to make, and load is what ties the counter to the switches.
  mirrorOk <- check "the switches reach the LEDs" [0x00A5] [ioLeds (P.last ioTrace)]
  upOk     <- check "btnU counts one press up"
                (P.map sevenSeg [1, 0, 0, 0]) (ioDigits 40)
  loadOk   <- check "btnR loads the switch value"
                (P.map sevenSeg [5, 0xA, 0, 0]) (ioDigits 110)
  downOk   <- check "btnD counts one press down"
                (P.map sevenSeg [4, 0xA, 0, 0]) (ioDigits 180)
  clearOk  <- check "btnL clears the counter"
                (P.map sevenSeg [0, 0, 0, 0]) (ioDigits 250)

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
  charOk  <- check "nibbles map to ASCII hex, upper case"
               [0x30, 0x31, 0x39, 0x41, 0x46] (P.map hexChar [0, 1, 9, 10, 15])
  nibOk   <- check "ASCII hex maps back, either case, and nothing else does"
               [Just 0, Just 9, Just 10, Just 15, Just 10, Just 15, Nothing, Nothing, Nothing]
               (P.map hexNibble [0x30, 0x39, 0x41, 0x46, 0x61, 0x66, 0x47, 0x20, 0x0D])
  -- The whole host vocabulary in one table. 'f' and 'j' are the pair that matters:
  -- they are adjacent in ASCII, and if the step keys were spelt any lower the hex
  -- digits would have to give one up.
  cmdOk   <- check "k and j step, either case, and hex digits still decode"
               [ Just Up, Just Up, Just Down, Just Down
               , Just (Digit 0), Just (Digit 15), Just (Digit 15)
               , Nothing, Nothing, Nothing ]
               (P.map typedAs
                  [ 0x6B, 0x4B, 0x6A, 0x4A     -- 'k' 'K' 'j' 'J'
                  , 0x30, 0x66, 0x46           -- '0' 'f' 'F'
                  , 0x69, 0x6C, 0x0A ])        -- 'i' 'l' LF, none of them ours

  -- The whole string, in order and once, though the trigger is held across the
  -- first bytes of it -- so a held button says a thing once rather than stuttering
  -- its first letter. 'busy' must have fallen by the end, or nothing downstream
  -- could ever tell that the transmitter is free again.
  sayOk   <- check "say hands a whole string to the transmitter, once"
               hi (mapMaybe (rxByte . P.fst) sayTrace)
  doneOk  <- check "and stops claiming the transmitter when it runs out of string"
               [(True, False)]
               [(P.any P.snd sayTrace, P.snd (P.last sayTrace))]

  -- The library's writing path, on its own transmitter and read back off the
  -- wire. 'said' spells the expected bytes by another route -- 'hexDigits' and a
  -- 'P.reverse' -- so this does not check 'word' against itself.
  spellOk <- check "hex spells a word most significant first, and line ends it"
               [0x30, 0x42, 0x45, 0x46, 0x0D, 0x0A] (toList (word 0x0BEF))
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

  -- The host link on the demo, in both directions at once: the reports are
  -- decoded off the design's own transmit pin, and the value they carry is the
  -- one the host typed. Out of reset the board greets the host and then reports
  -- the counter unprompted. The greeting's bytes come from 'IoDemo' rather than
  -- being spelt out: these two traces are about the counter, and pinning the exact
  -- prose here only made rewording the greeting fail them. What is worth pinning
  -- about it is that it is a line, which 'greetOk' does and a reword cannot break.
  greetOk  <- check "the greeting is a line of text, ended so a terminal starts a new one"
                [True, True]
                [ P.all (\c -> c >= 0x20 && c < 0x7F)
                        (P.take (P.length greeted - 2) greeted)
                , P.drop (P.length greeted - 2) greeted == [0x0D, 0x0A] ]
  reportOk <- check "the board greets the host, then reports the counter as it is typed in"
                ( greeted
                    P.++ P.concatMap said [0x0000, 0x000B, 0x00BE, 0x0BEE, 0xBEEF] )
                (mapMaybe (rxByte . P.snd) hostTrace)
  typedOk  <- check "and the display agrees with what the host was told"
                (P.map sevenSeg [0xF, 0xE, 0xE, 0xB])
                (digitsOf (P.map P.fst (P.drop (watching 4 - 40) hostTrace)))
  stillOk  <- check "while the LEDs go on mirroring the switches"
                [0x00A5] [ioLeds (P.fst (P.last hostTrace))]

  -- k, K, j from the host: one step each, in the direction asked for, and the
  -- host told about every one of them. Two ups and a down must land back on 1
  -- rather than anywhere near 2, which is what catches a keystroke counted twice.
  stepOk   <- check "k counts up and j counts down, one step per keystroke"
                ( greeted P.++ P.concatMap said [0x0000, 0x0001, 0x0002, 0x0001] )
                (mapMaybe (rxByte . P.snd) stepTrace)
  stepSegOk <- check "and the display ends up where the host was told it would"
                (P.map sevenSeg [1, 0, 0, 0])
                (digitsOf (P.map P.fst (P.drop (watching 3 - 40) stepTrace)))
  faultOk  <- check "a bad stop bit lights the decimal point and leaves it lit"
                [(high, low)]
                -- Bound over 'P.take 1' rather than taken with 'P.head': an empty
                -- trace then compares unequal instead of throwing.
                [(ioPoint f, ioPoint (P.last faultTrace)) | f <- P.take 1 faultTrace]

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

  -- The board wrapper, end to end: LED 15 set for ready, no failure flag on
  -- LED 14, stage 7 in the low nibble, and both switches reading low.
  ledsOk  <- check "the demo's LEDs report a card that came up"
               [0x8007] [demoLeds (P.last demoTrace)]
  -- And the payoff: the signature at the end of the block, on the display.
  showOk  <- check "the demo displays 55AA once the block has been read"
               (P.map sevenSeg [0xA, 0xA, 0x5, 0x5]) demoDigits

  unless (P.and [ blinkOk, walkOk, carryOk, wrapOk, segOk, hexOk, splitOk
                , pressOk, quietOk, bankOk
                , mirrorOk, upOk, loadOk, downOk, clearOk
                , frameOk, markOk, loopOk, cleanOk, noiseOk, breakOk
                , charOk, nibOk, cmdOk, sayOk, doneOk
                , spellOk, freezeOk, mergeOk, firstOk, orderOk, quietSrcOk
                , greetOk, reportOk, typedOk, stillOk, stepOk, stepSegOk, faultOk
                , crcOk, echoOk, readyOk, failOk, ocrOk, idxOk, dataOk, sigOk
                , deadOk, retryOk, ledsOk, showOk
                ]) exitFailure
