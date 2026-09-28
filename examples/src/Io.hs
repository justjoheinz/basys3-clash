{-|
The board's own inputs, which no other design here touches -- the 16 slide
switches and the four outer push buttons -- and its link to the host.

What it does, and what each part of it is there to prove:

  * The LEDs mirror the switches, through @bank@. Throw a switch and the LED
    above it follows -- which is the whole switch bank and its conditioning,
    checked by eye.
  * The display shows a 16-bit counter as four hex digits, and the buttons drive
    it: btnU counts up, btnD counts down, btnR loads whatever the switches read,
    btnL clears it to zero. One press has to be one step, which is the claim
    debouncing exists to make: an unconditioned button would jump several counts
    per press, and that is exactly what this shows or fails to show.
  * Whenever the counter changes, its four digits go to the host as ASCII,
    followed by carriage return and line feed. The terminal and the display read
    the same, which is what makes the link self-checking: nothing has to be
    believed about the baud rate, because a wrong one garbles the text while the
    display stays right.
  * A hex digit typed at the host shifts the counter left by four bits and drops
    that nibble in. Typing @beef@ walks the display through @000B@, @00BE@,
    @0BEE@, @BEEF@.
  * @k@ counts up and @j@ counts down, either case -- the same direction they
    mean in @vi@ and @less@, so the keys need no learning. They are btnU and
    btnD from the keyboard, and the check that they are: hold @k@ down and the
    display should climb at the terminal's auto-repeat rate.
  * Anything else the host sends is ignored, so a stray newline or a pasted
    prompt does nothing.
  * The decimal point lights, and stays lit, if a frame ever arrives with its
    stop bit low. That is what a terminal set to the wrong speed looks like from
    this end, and without a light for it the symptom is silence.
  * btnC resets the domain, as in every design here, and is debounced for it --
    see 'topEntity'. The board greets the host and
    then reports the counter, which is how to check the link without touching
    anything else -- and the greeting is the smaller check of the two, because
    it needs nothing to be true about the counter for its letters to be legible.
    It also says which keys do what, a terminal being the one place a design can
    explain itself. The cost is 88 bytes, about 7.6 ms, during which it holds the
    transmitter and the first counter report waits.

Load and clear are what make the switches and the counter check each other: set
the switches to a value, press btnR, and the display should read what the LEDs
are showing -- and the host is told the same value, so btnR doubles as "send me
the switches".
-}
module Io
  ( Typed (..)
  , greeting
  , io
  , topEntity
  , typedAs
  , word
  ) where

import Basys3.Board

-- | What the board says when it comes out of reset. Exported so the tests can
-- derive both the bytes they expect and how long they take to leave, rather than
-- writing either out: this is prose, it will be reworded, and a reworded greeting
-- should not fail a test about the counter.
greeting :: Vec 88 (BitVector 8)
greeting = $(ascii "Hello. To increase/decrease the counter, send 'k' or 'j' - or use the Up/Down buttons.\r\n")

-- | How this design spells its counter for the host: four hex digits most
-- significant first, then CR LF. Six bytes, about 520 microseconds at 115200.
--
-- The signature is what settles 'hex''s digit count -- @n@ is solved from the
-- result -- so nothing here needs a type application.
word :: BitVector 16 -> Vec 6 (BitVector 8)
word = line . hex

-- | What the host can ask for. One byte is one whole request, which is what keeps
-- the receiving end stateless: there is nothing to remember between frames, so
-- nothing can be half-said and there is no partial command to time out.
data Typed
  = Digit (Unsigned 4)
    -- ^ A hex digit, to be shifted in from the right.
  | Up
    -- ^ Count up, as btnU does.
  | Down
    -- ^ Count down, as btnD does.
  deriving (Generic, NFDataX, Show, Eq)

-- | One byte as what it asks for, and 'Nothing' for everything else -- which is
-- most of what a terminal sends, a newline included.
--
-- @k@ is up and @j@ is down because that is what they mean in @vi@ and @less@.
-- They do not collide with the hex digits: @j@ and @k@ are @0x6A@ and @0x6B@,
-- immediately past @f@ at @0x66@, which is the only reason this can be one flat
-- decode rather than a mode.
typedAs :: BitVector 8 -> Maybe Typed
typedAs c
  | c == 0x6B || c == 0x4B = Just Up    -- 'k', 'K'
  | c == 0x6A || c == 0x4A = Just Down  -- 'j', 'J'
  | otherwise              = Digit <$> hexNibble c

-- | The design. The two cycle counts and the bit period are parameters for the
-- same reason 'Blinky.blinky''s period is: a five-millisecond debounce is 500e3
-- cycles and one UART bit is 868, neither of which a test wants to simulate.
io
  :: forall dom
   . HiddenClockResetEnable dom
  => Unsigned 32
  -- ^ Cycles - 1 a contact must hold still.
  -> Unsigned 32
  -- ^ Cycles - 1 that each display digit is held lit.
  -> Unsigned 16
  -- ^ Cycles - 1 per UART bit; 'Basys3.baud115200' on the board.
  -> Signal dom Switches
  -> Signal dom Bit  -- ^ btnU, count up
  -> Signal dom Bit  -- ^ btnD, count down
  -> Signal dom Bit  -- ^ btnL, clear
  -> Signal dom Bit  -- ^ btnR, load the switches
  -> Signal dom Bit  -- ^ uart_rx, the line from the host
  -> Signal dom (Leds, Display, Bit)
-- 'hold' rather than 'dwell' and 'held'/'press' rather than 'pressed': the board's
-- names for all three are in scope through "Basys3.Board", and this circuit takes
-- its own timings precisely so as not to use them.
io contacts hold period sw up down left right rxPin =
  bundle (leds, Display <$> seg <*> anode <*> point, uartOut)
 where
  -- The switches, debounced, straight onto the LEDs.
  leds = bank contacts sw

  -- One pulse per press.
  press = snd . contact contacts

  count  = register 0 (bump <$> count <*> inputs)
  inputs = bundle (press left, press right, press up, press down, leds, typed)

  -- Clear beats load beats up beats down beats the host, so pressing two things
  -- at once is defined rather than merely whatever the hardware happens to do.
  -- The person at the board outranks the person at the keyboard, which is what
  -- makes btnL a way out of a paste that is still arriving.
  --
  -- Nothing here waits for the host. 'typed' is 'Just' for exactly the one cycle
  -- a frame finishes on, so a keystroke is an input to this cycle's update like
  -- any button, and a cycle with no byte in it is simply a cycle where the guard
  -- does not fire.
  bump c (clear, load, plus, minus, sws, asked)
    | clear                 = 0
    | load                  = sws
    | plus                  = c + 1
    | minus                 = c - 1
    | Just Up        <- asked = c + 1
    | Just Down      <- asked = c - 1
    | Just (Digit d) <- asked = shiftL c 4 .|. zeroExtend (pack d)
    | otherwise               = c

  (seg, anode) = display (prescaler hold) (hexDigits <$> count)

  -- The host link, both directions. Two things talk: the greeting, once, and
  -- the counter reports for ever after. 'Serial.before' is the whole of the
  -- arbitration -- the greeting wins outright and the reporter is simply told
  -- the transmitter is busy until it finishes.
  --
  -- Every byte the host sends is either a whole request or ignored, so the
  -- receiving end has one client and needs no queue either: a byte is consumed
  -- by the cycle it arrives on or not at all.
  (uartOut, heard) = serial period rxPin
                       (say greeting atReset `before` report word count)
  typed = decoded typedAs heard

  -- A framing error is one cycle wide and means the far end is running at a
  -- different speed, so 'latch' it: the decimal point is active low like the rest
  -- of the display, hence the 'not'.
  faulty = latch (rxError <$> heard)
  point  = boolToBit . not <$> faulty

-- | 'Basys3.settle' is 5 ms, long enough for any of these contacts to stop
-- bouncing. Each display digit is held for 100e3 cycles (1 ms), giving a 250 Hz
-- refresh, as in the other designs, and the host link runs at 115200 baud.
--
-- btnC gets the same 5 ms through 'Basys3.onBoard', for the reason
-- 'Basys3.settle' gives -- and this is the design where the difference is
-- audible rather than theoretical. An undebounced reset restarts the domain once
-- per bounce, and each restart lands in the middle of whichever frame was on the
-- wire: the transmitter's line register comes out of reset at mark
-- ("Protocol.UART"), so the host, already past a start bit, reads the rest of
-- that byte as ones and prints one piece of gibberish before the greeting begins
-- again. One press now costs at most one such byte instead of one per bounce.
-- Nothing in the domain can do better than that: by the time reset arrives the
-- frame is already half spoken.
topEntity
  :: Clock Basys3
  -> Reset Basys3
  -> Signal Basys3 Switches
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 Bit
  -> Signal Basys3 (Leds, Display, Bit)
topEntity clk rst sw up down left right rxPin =
  onBoard clk rst (io settle 99_999 baud115200 sw up down left right rxPin)
{-# NOINLINE topEntity #-}
{-# ANN topEntity
  (basys3 "io"
    (switchesPort : buttonPorts <> [uartRxPort])
    (ports [ledsPort, displayPort, uartTxPort])) #-}
