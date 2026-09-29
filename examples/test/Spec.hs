-- | Haskell-level simulation of the designs. Runs in seconds and needs no HDL
-- simulator at all: @stack test@.
--
-- Only what needs a design in scope is here. Everything the library claims on its
-- own -- the UART's frames, the debouncer, base ten, the SD controller against a
-- pretend card -- is checked in the @basys3@ package's own suite (@spec\/@), which
-- is where somebody bumping the snapshot looks and where the library's usage
-- examples are worth having. This half is the other question: whether the three
-- designs put those parts together the way their documentation says.
--
-- 'check', 'frame' and 'said' are the same few lines in both suites. Copied
-- rather than shared: a fixture that crosses a package boundary has to be exported
-- by one of them, and a library should not export its test harness to make its own
-- tests tidier.
module Main (main) where

import           Clash.Prelude
import           Control.Monad (unless)
import           Data.Maybe    (fromMaybe, listToMaybe, mapMaybe)
import qualified Prelude       as P
import           System.Exit   (exitFailure)

-- Named imports throughout, rather than the single "Basys3.Board" a design uses:
-- a test that pins a byte should also pin where the byte's spelling came from,
-- and a name moving between modules is something this file ought to notice.
import           Ascii                     (hexChar)
import           Basys3                    (Display (..), Leds, prescaler)
import           Blinky                    (blinky, rotator)
import           Io                        (Typed (..), greeting, io, typedAs)
import           Peripheral.SevenSegment   (hexDigits, sevenSeg)
import           Protocol.UART             (UartRx (..), uartRx)

-- | What 'Blinky.topEntity' drives: the 16 LEDs, and nothing else.
type Out = Leds

-- | With a blink limit of 2 each half of the blink lasts three cycles, so twelve
-- samples are two whole blinks -- starting dark, because that is where
-- 'Blinky.blinkState' comes out of reset.
expectedBlink :: [Out]
expectedBlink = P.concatMap (P.replicate 3) [0x0000, 0xFFFF, 0x0000, 0xFFFF]

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
  out = withClockResetEnable clockGen resetGen enableGen (blinky 2)

simulatedWalk :: [BitVector 16]
simulatedWalk = postReset (P.length expectedWalk) leds
 where
  leds = withClockResetEnable clockGen resetGen enableGen (rotator (prescaler 2))

-- | One clean press starting at cycle @from@ and held for 15 cycles: long
-- enough to survive 'io''s debouncing, short enough to finish before the
-- next one. Infinite, so 'fromList' never runs out.
held :: P.Int -> [Bit]
held from = [if i >= from && i P.< from P.+ 15 then high else low | i <- [0 ..]]

-- | What 'Io.topEntity' drives: the LEDs, the display's three pins, and its
-- transmit pin.
type IoOut = (Leds, Display, Bit)

ioLeds :: IoOut -> Leds
ioLeds (l, _, _) = l

ioScan :: IoOut -> (BitVector 7, BitVector 4)
ioScan (_, d, _) = (cathodes d, anodes d)

-- | The decimal point, which this design uses as its framing-error light. Active
-- low, so 'low' is lit.
ioPoint :: IoOut -> Bit
ioPoint (_, d, _) = decimalPoint d

ioTx :: IoOut -> Bit
ioTx (_, _, t) = t

-- | The switch-and-button design, driven through all four of its buttons in
-- turn with the switches held at 0x00A5: up, then load, then down, then clear.
-- A settle of four cycles and a dwell of five keep the whole run to 300 cycles.
-- Nothing arrives from the host, so the transmit side is ignored here.
ioTrace :: [IoOut]
ioTrace = sampleN 300
            (withClockResetEnable clockGen resetGen enableGen
               (io 3 4 7 (pure 0x00A5)
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

-- | One 8N1 frame as the host's end of the wire would drive it, @width@ cycles a
-- bit: a low start bit, eight data bits least significant first, then whatever
-- stop level is wanted. Built by hand rather than with 'Protocol.UART.uartTx', so
-- what these traces feed the design is what a terminal drives.
frame :: P.Int -> Bit -> BitVector 8 -> [Bit]
frame width stop b = P.concatMap (P.replicate width)
  (low : [if testBit b k then high else low | k <- [0 .. 7]] P.++ [stop])

-- | A report as the host should see it: four hex characters most significant
-- first, then CR LF. Spelt with 'hexDigits' and a 'P.reverse' rather than with
-- 'Io.word', so this does not check the design's spelling against itself.
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
  out = io 3 4 7 (pure 0x00A5) (pure low) (pure low) (pure low) (pure low)
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
  out = io 3 4 7 (pure 0x00A5) (pure low) (pure low) (pure low) (pure low)
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
                  (io 3 4 7 (pure 0) (pure low) (pure low) (pure low) (pure low)
                     (fromList (P.replicate 16 high
                                  P.++ frame 8 low 0x41
                                  P.++ P.repeat high))
                   :: Signal System IoOut))

check :: (P.Eq a, P.Show a) => P.String -> [a] -> [a] -> P.IO Bool
check name expected actual
  | actual P.== expected = do
      P.putStrLn ("designs: " P.++ name P.++ " matches")
      P.pure True
  | P.otherwise = do
      P.putStrLn ("designs: " P.++ name P.++ " MISMATCH")
      P.putStrLn ("  expected: " P.++ P.show expected)
      P.putStrLn ("  actual:   " P.++ P.show actual)
      P.pure False

main :: P.IO ()
main = do
  blinkOk <- check "the LEDs blink together" expectedBlink simulatedBlink
  walkOk  <- check "one-hot walk"            expectedWalk  simulatedWalk

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

  -- The host link on the demo, in both directions at once: the reports are
  -- decoded off the design's own transmit pin, and the value they carry is the
  -- one the host typed. Out of reset the board greets the host and then reports
  -- the counter unprompted. The greeting's bytes come from 'Io' rather than
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

  -- Nothing here drives the `sd` design. Doing that needs a pretend card, and the
  -- pretend card is test code that lives in the library's own suite (spec/) --
  -- another package, so this one cannot see it. What `sd` puts on the LEDs and the
  -- display is therefore unchecked; `spec/` covers the controller underneath it.
  unless (P.and [ blinkOk, walkOk
                , mirrorOk, upOk, loadOk, downOk, clearOk, cmdOk
                , greetOk, reportOk, typedOk, stillOk, stepOk, stepSegOk, faultOk
                ]) exitFailure
