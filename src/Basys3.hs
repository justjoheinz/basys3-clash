-- createDomain generates a KnownDomain instance, which GHC classes as an
-- orphan. That is the normal way to declare a clock domain in Clash.
{-# OPTIONS_GHC -Wno-orphans #-}

{-|
The board itself, as opposed to any one design on it: its clock domain, the
widths of the things bolted to its pins, the cycle counts that suit a 100 MHz
clock, and the general-purpose circuits with those counts already applied.

Both of the last two are here on purpose, and choosing between them is the
difference between a design and a design with a test suite:

  * 'switches', 'button', 'pressed', 'showHex' and 'host' are the parts under
    @Peripheral@ and @Protocol@ with this board's timings already in them. They
    take a signal and give one back, and nothing about five milliseconds or 868
    cycles appears in the design at all. Reach for these first.
  * 'settle', 'dwell' and 'baud115200' are those same timings as bare numbers,
    for the same circuits taken directly. A design that wants to be simulated in
    a few hundred cycles rather than a few hundred thousand has to pass its own
    instead -- 'Io' takes all three as arguments, which is the whole reason
    it has a test suite, and its @topEntity@ is where the board's real numbers go
    in.

What is underneath:

  * "Peripheral.SevenSegment" drives the display; 'Digits' is this board's
    four-digit instance of it, 'Display' its three pins, and 'showHex' the whole
    of it at 'dwell'.
  * "Peripheral.Button" conditions the buttons and switches, at 'settle' cycles:
    'switches' and 'button'. btnC waits the same 'Settle' for its contact to stop
    bouncing, but through 'resetGlitchFilter', because it is the reset itself --
    which 'onBoard' does so that no design has to.
  * "Serial" and "Protocol.UART" talk to the host over the board's USB-serial
    bridge, at 'baud115200' cycles per bit: 'host'.
  * "Screen" and "Protocol.VGA" drive the VGA connector, one pixel every 'dot' + 1
    cycles: 'screen' is 640x480 at 60 Hz with that rate already in it, 'Vga' its
    14 pins and 'Colour' what they can show.

The board also has 16 LEDs, which need no logic at all: 'Leds' is just wires.

What is left of a design is then its ports, one line of wiring, and whatever it
is actually for:

@
counter :: 'HiddenClockResetEnable' 'Basys3' => 'Signal' 'Basys3' 'Switches' -> 'Signal' 'Basys3' ('Leds', 'Display')
counter sw = 'bundle' (leds, 'showHex' leds)
 where leds = 'switches' sw

topEntity :: 'Clock' 'Basys3' -> 'Reset' 'Basys3' -> 'Signal' 'Basys3' 'Switches' -> 'Signal' 'Basys3' ('Leds', 'Display')
topEntity clk rst sw = 'onBoard' clk rst (counter sw)
{-\# ANN topEntity ('basys3' "counter" ['switchesPort'] ('ports' ['ledsPort', 'displayPort'])) \#-}
@

The pin /names/ are part of that. Every one of them appears in a file under
@constraints\/@ and has to be spelt the same way here, so they are spelt once
each, as the 'PortName' values below, and every annotation is built out of those
rather than out of string literals -- see 'basys3'.

"Basys3.Board" is this module and everything it draws on in a single import,
which is what a design should use.
-}
module Basys3
  ( -- * The board
    Basys3
  , vBasys3
  , onBoard
  , prescaler
    -- * What is wired to the pins
  , Digits
  , Display (..)
  , Leds
  , Switches
  , Vga (..)
  , Colour
    -- * Reading its contacts
  , Settle
  , settle
  , switches
  , button
  , pressed
    -- * Driving its display
  , dwell
  , showDigits
  , showHex
  , withPoint
    -- * Driving its screen
  , dot
  , pixel
  , vgaPins
  , screen
    -- * Talking to the host
  , baud115200
  , host
    -- * Naming the pins
  , basys3
  , ports
  , clockPort
  , resetPort
  , ledsPort
  , displayPort
  , switchesPort
  , buttonPorts
  , btnUPort
  , btnDPort
  , btnLPort
  , btnRPort
  , uartRxPort
  , uartTxPort
  , vgaPort
  ) where

import Clash.Prelude

import Peripheral.Button       (bank, contact)
import Peripheral.SevenSegment (display, hexDigits)
import Screen                  (Rgb (..), Scan (..), black, scan, vga640x480at60)
import Serial                  (Source, UartRx, serial)

-- | The Basys3 has a single-ended 100 MHz oscillator on pin W5. We use the
-- centre push button (btnC, pin U18) as reset, which reads high when pressed,
-- hence 'ActiveHigh'.
createDomain vSystem{ vName          = "Basys3"
                    , vPeriod        = hzToPeriod 100e6
                    , vResetPolarity = ActiveHigh
                    }

-- | Put a circuit on the board: the 100 MHz clock, btnC as a debounced reset,
-- and the enable line tied high. This is the whole of what a @topEntity@ has to
-- do besides naming its ports.
--
-- @
-- topEntity clk rst = 'onBoard' clk rst (blinky 99_999_999)
-- @
--
-- The reset arrives through 'resetGlitchFilter' at 'Settle', which is the one
-- piece of this that is not obvious and the reason it is worth a function: see
-- 'settle' for why btnC cannot be conditioned like any other contact, and
-- 'Io.topEntity' for what it sounds like when it is not conditioned at all.
--
-- Nothing a design might want to choose is hidden. The clock and reset stay
-- arguments, so a test bench can substitute its own, and the circuit's own
-- timings stay its own arguments, so a simulation can still pick small ones.
onBoard
  :: Clock Basys3
  -> Reset Basys3
  -> (HiddenClockResetEnable Basys3 => r)
  -- ^ The design, which may take its clock, reset and enable implicitly.
  -> r
onBoard clk rst =
  withClockResetEnable clk (resetGlitchFilter (SNat @Settle) clk rst) enableGen

-- | Pulses high for exactly one cycle every @limit + 1@ cycles.
prescaler :: HiddenClockResetEnable dom => Unsigned 32 -> Signal dom Bool
prescaler limit = tick
 where
  count = register 0 next
  next  = mux tick 0 (count + 1)
  tick  = (== limit) <$> count

-- | Four display digits, least significant first: index 0 is driven onto AN0,
-- which is the rightmost digit on the board.
type Digits = Vec 4 (Unsigned 4)

-- | The three pins of the four-digit display, as one value, which is what
-- "Peripheral.SevenSegment" produces the first two of.
--
-- A record rather than the tuple this used to be because a tuple of pins is only
-- documented by its order: @('BitVector' 7, 'BitVector' 4, 'Bit')@ tells you
-- nothing about which is which, and getting it wrong costs a bitstream and a
-- puzzled look at the board rather than a type error. Naming them also means the
-- port list can be checked against the field it came from.
data Display = Display
  { cathodes     :: BitVector 7
    -- ^ CA..CG, shared by all four digits. Active low, so a clear bit lights its
    -- segment -- 'Peripheral.SevenSegment.sevenSeg' already accounts for that.
  , anodes       :: BitVector 4
    -- ^ AN0..AN3, which digit is lit. Active low, and exactly one bit should be
    -- clear at a time; bit 0 is the rightmost digit.
  , decimalPoint :: Bit
    -- ^ The dot between the digits. Active low like the rest of the display, so
    -- 'high' is dark -- which is what a design with nothing to say with it wants.
    -- 'Io' uses it as a lamp for one specific fault.
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Show, Eq)

-- | The 16 LEDs in a row above the switches, bit 0 rightmost. Active high, and
-- nothing stands between the register and the pin.
type Leds = BitVector 16

-- | The 16 slide switches along the bottom edge, bit 0 rightmost. High when the
-- switch is up. Pass them through 'switches' before using them: this is the pin
-- as it comes off the pad, and a slide switch bounces like any other contact.
type Switches = BitVector 16

-- | The 14 pins of the VGA connector, as one value, for the reason 'Display' is a
-- record: a tuple of three colour channels and two syncs is documented only by its
-- order, and getting red and blue the wrong way round is a bitstream and a puzzled
-- look at a monitor rather than a type error.
--
-- Built by 'vgaPins' and driven by 'screen'; a design should not need to name the
-- fields.
data Vga = Vga
  { redPin   :: BitVector 4
    -- ^ Pins G19, H19, J19, N19, bit 0 least significant.
  , greenPin :: BitVector 4
    -- ^ Pins J17, H17, G17, D17.
  , bluePin  :: BitVector 4
    -- ^ Pins N18, L18, K18, J18.
  , hsyncPin :: Bit
    -- ^ Pin P19. Active low at 640x480, which is a property of the mode and not
    -- of the board -- 'Protocol.VGA.Polarity' is where that is said.
  , vsyncPin :: Bit
    -- ^ Pin R19.
  }
  deriving (Generic, NFDataX, BitPack, ShowX, Show, Eq)

-- | What this board's connector can show: four bits per channel, so 4096 colours.
--
-- Each channel is a resistor DAC into the monitor's 75 ohm termination, sized for
-- it, so a channel driven high is a voltage rather than a short -- but it is also
-- not a digital output whose level means anything on its own. "Screen" is where a
-- colour comes from, at whatever depth the pixel was stored at.
type Colour = Rgb 4

-- | Cycles a contact must read steady before the board believes it: 5 ms at
-- 100 MHz. Tactile switches and slide switches of this kind bounce for a few
-- hundred microseconds, so this is roughly an order of magnitude clear of the
-- problem while staying far below the ~50 ms at which a button starts to feel
-- unresponsive.
--
-- At the type level because one of its two users can only have it that way:
-- 'resetGlitchFilter' takes an 'SNat', so btnC's five milliseconds cannot be a
-- value. Naming the number once and deriving 'settle' from it is what stops the
-- reset's idea of /settled/ drifting from every other contact's.
type Settle = 500_000

-- | 'Settle' as "Peripheral.Button" wants it, which is cycles minus one.
--
-- 'switches' and 'button' are this number already applied, and are what a design
-- should use. It is exported for the design that cannot: five milliseconds is
-- 500,000 cycles, and a test that has to simulate them is a test nobody runs, so
-- a circuit meant to be tested takes its settle time as an argument and is handed
-- this one from @topEntity@. 'Io' is that shape; 'Sketch' is the other.
--
-- All five buttons read high when pressed, so the pin goes straight in. btnC is
-- not among them: it is the reset, and a debouncer for it cannot be built out of
-- 'Peripheral.Button.debounce', whose registers live in this domain and would be
-- held at their initial state by the very reset they are meant to release --
-- asserting reset, clearing the counter, releasing reset, counting again, which
-- is a 5 ms oscillator rather than a debounced button. 'resetGlitchFilter' is the
-- same wait built where that loop cannot close: it takes a bare 'Clock' and no
-- 'Reset', so nothing it contains can be held by its own output. 'onBoard' wraps
-- btnC in it at 'Settle', which is why no design here mentions either.
settle :: Unsigned 32
settle = snatToNum (SNat @Settle) - 1

-- | The 16 slide switches, conditioned: 'Peripheral.Button.bank' at 'settle', so
-- the reading only changes once every bit has held still for 5 ms.
--
-- Straight onto the LEDs is a complete design:
--
-- @
-- mirror sw = 'bundle' ('switches' sw, 'showHex' ('switches' sw))
-- @
switches
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Switches
  -> Signal Basys3 Switches
switches = bank settle

-- | One push button, conditioned: the steady level, and one cycle of 'True' per
-- press. 'Peripheral.Button.contact' at 'settle'.
--
-- Hand it the pin as it comes off the pad -- all five buttons on this board read
-- high when pressed, so nothing needs inverting.
button
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Bit
  -> (Signal Basys3 Bool, Signal Basys3 Bool)
  -- ^ Held, and one pulse per press.
button = contact settle

-- | Just the pulse from 'button', which is what a counter wants: one press, one
-- step.
pressed
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Bit
  -> Signal Basys3 Bool
pressed = snd . button

-- | Cycles each display digit is held lit, minus one: 1 ms, so all four are
-- visited in 4 ms and the display refreshes at 250 Hz. Fast enough that the eye
-- sees four digits rather than a flicker, slow enough that the scan is nowhere
-- near the limits of anything.
--
-- 'showDigits' and 'showHex' are this number already applied. Exported for the
-- reason 'settle' is: a test cannot afford 400,000 cycles to watch the scan go
-- round once.
dwell :: Unsigned 32
dwell = 99_999

-- | The whole display: four digits, scanned at 'dwell', decimal point dark.
--
-- Least significant digit first, so index 0 is the rightmost on the board --
-- 'Digits' says the same thing.
showDigits
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Digits
  -> Signal Basys3 Display
showDigits digits = Display <$> seg <*> anode <*> pure high
 where
  (seg, anode) = display (prescaler dwell) digits

-- | A 16-bit value as four hex digits on the display, reading the way it is
-- written: @0x55AA@ shows as @55AA@.
--
-- Hex because four digits is what the board has. Decimal needs five for 16 bits,
-- and "Ascii.dec" is where a number goes when it has to be read in base ten --
-- the host has room for it.
showHex
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 (BitVector 16)
  -> Signal Basys3 Display
showHex = showDigits . fmap hexDigits

-- | Light the decimal point, or leave it dark: @'withPoint' faulty ('showHex'
-- count)@.
--
-- Takes the sense a design thinks in -- 'True' is lit -- and does the active-low
-- inversion the pin wants, which is the kind of thing worth getting wrong in
-- exactly one place. The dot is the one lamp on this board that means whatever a
-- design says it means, being the only segment not spoken for by a digit.
withPoint
  :: Signal Basys3 Bool
  -- ^ Lit.
  -> Signal Basys3 Display
  -> Signal Basys3 Display
withPoint lit = liftA2 set lit
 where
  set on d = d { decimalPoint = boolToBit (not on) }

-- | Clock cycles per pixel, minus one, for 640x480 at 60 Hz: three, so the beam
-- advances at 100e6 \/ 4 = 25.000 MHz.
--
-- The mode asks for 25.175 MHz. 100 MHz does not divide to it, so the raster runs
-- 0.7% slow and the frame rate comes out at 59.52 Hz instead of 59.94 -- outside
-- VESA's tolerance on paper, and accepted by every monitor anyone has tried it on,
-- because what a monitor actually locks onto is the two sync pulses and it measures
-- their period for itself. 'Protocol.VGA.refresh' is that arithmetic if you want to
-- see it.
--
-- Exported bare for the reason 'settle', 'dwell' and 'baud115200' are, and for one
-- specific to it: closing the gap means an MMCM, and if this flow ever grows one
-- then the number that changes is this one.
dot :: Unsigned 32
dot = 3

-- | The pixel rate as a clock /enable/: 'prescaler' at 'dot', so one cycle in four.
--
-- __Not a second clock domain, on purpose.__ A 25 MHz domain beside the board's 100
-- MHz one would need an MMCM to generate it, a second @create_clock@, and a
-- @set_clock_groups@ to stop the router timing paths between the two -- and
-- nextpnr-xilinx silently ignores the constraints it does not implement, so that
-- last one would sit in the file looking present and do nothing. An enable has none
-- of those parts: every register in the design stays in 'Basys3', every path is
-- checked against 10 ns, and there is no crossing to get wrong.
--
-- The cost is that three cycles in four do nothing, which on a design whose entire
-- pixel path is a few comparisons is not a cost.
pixel :: HiddenClockResetEnable Basys3 => Signal Basys3 Bool
pixel = prescaler dot

-- | One pixel period's worth of beam and colour, as the 14 pins.
--
-- Pure, like 'Pmod.SdCard.sdPins', and it is the one place blanking is enforced:
-- the colour is forced to 'Screen.black' whenever 'scanAt' is 'Nothing', whatever
-- the pixel function said. A monitor measures its own black level during the
-- porches, so a picture painted through one comes out washed out across the whole
-- screen -- and that is a bug that looks like a bad cable. Enforcing it here means
-- a design cannot have it, rather than having to remember not to.
vgaPins :: Scan -> Colour -> Vga
vgaPins beam colour = Vga
  { redPin   = rgbRed   shown
  , greenPin = rgbGreen shown
  , bluePin  = rgbBlue  shown
  , hsyncPin = scanHsync beam
  , vsyncPin = scanVsync beam
  }
 where
  shown
    | Just _ <- scanAt beam = colour
    | otherwise             = black

-- | The whole screen: 640x480 at 60 Hz on this board's connector, given something
-- that says what colour each pixel is.
--
-- @
-- outline :: 'Signal' 'Basys3' 'Scan' -> 'Signal' 'Basys3' 'Colour'
-- outline = 'fmap' at
--  where
--   at beam = case 'scanAt' beam of
--     Just p  -> 'Screen.mono' ('Screen.border' 4 (640, 480) p)
--     Nothing -> 'Screen.black'
--
-- topEntity :: 'Clock' 'Basys3' -> 'Reset' 'Basys3' -> 'Signal' 'Basys3' 'Vga'
-- topEntity clk rst = 'onBoard' clk rst ('screen' outline)
-- {-\# ANN topEntity ('basys3' "outline" [] 'vgaPort') \#-}
-- @
--
-- The 'Nothing' branch is written because the @case@ has to be total, not because
-- anything depends on it: 'vgaPins' blanks the porches whatever it said.
--
-- The pixel function is an argument rather than this returning a 'Scan' for a
-- design to finish, which is what keeps the colour and the syncs aligned: there is
-- one 'register' across the whole record, so all 14 pins leave on the same edge and
-- the colour cannot arrive a cycle after the sync that framed it. Handing back a
-- scan would put that register in the design, four times over, and nothing would
-- say so.
--
-- It is also why the argument takes and returns a 'Signal': a pixel function is
-- welcome to have state -- a framebuffer read is exactly that -- provided it adds
-- no latency of its own relative to the beam.
screen
  :: HiddenClockResetEnable Basys3
  => (Signal Basys3 Scan -> Signal Basys3 Colour)
  -- ^ What colour the beam is on. Only consulted where 'scanAt' is 'Just'.
  -> Signal Basys3 Vga
screen paint = register dark (vgaPins <$> beam <*> paint beam)
 where
  beam = scan vga640x480at60 pixel

  -- Blank, with both syncs where 640x480 idles them, which is high: they are
  -- active low. Built through 'vgaPins' rather than written out, so it cannot
  -- disagree with what the first real pixel period produces -- and it matches
  -- 'scan''s own reset state, which is the top left corner.
  dark = vgaPins Scan { scanHsync = high
                      , scanVsync = high
                      , scanAt    = Nothing
                      , scanFrame = False
                      } black

-- | Clock cycles per UART bit, minus one, for 115200 baud: 100e6 \/ 115200 is
-- 868.06, so each bit is 868 cycles and the divisor "Protocol.UART" wants is 867.
-- That rounding puts the realised rate at 100e6 \/ 868 = 115207 baud, which is
-- 0.006% fast.
--
-- What that error has to beat: a receiver samples the stop bit nine and a half
-- bit periods after the start edge, so the two ends' rates may differ by just
-- under 5% before a sample lands in the wrong bit. Our 0.006% leaves effectively
-- the whole budget to the host's end of the cable.
--
-- 'host' is this number already applied. Exported for the reason 'settle' is,
-- and for one more: this is the divisor for /this/ rate, and a design is entitled
-- to want another. 'Unsigned 16' bottoms out at 65535, which is
-- 100e6 \/ 65536 = 1526 baud: every standard rate from 2400 up fits, 1200 would
-- not. Other rates are @round (100e6 \/ baud) - 1@, so 9600 is 10416.
baud115200 :: Unsigned 16
baud115200 = 867

-- | The host link, both directions, at 115200 baud: give it the receive pin and
-- something to say, and it hands back the transmit pin and everything heard.
--
-- @
-- (tx, heard) = 'host' rxPin ('Serial.say' greeting 'Serial.atReset' \`'Serial.before'\` 'Serial.report' spell count)
-- @
--
-- "Serial" is where the sources come from and what a design says with them; this
-- is only that module with the board's divisor in it. 8N1, no flow control,
-- because the two handshake lines are not brought out to the FPGA -- see
-- @constraints\/Basys3-Uart.xdc@.
host
  :: HiddenClockResetEnable Basys3
  => Signal Basys3 Bit
  -- ^ uart_rx, straight from the pad.
  -> Source Basys3
  -- ^ What to say, however many clients that is: see 'Serial.before'.
  -> (Signal Basys3 Bit, Signal Basys3 UartRx)
  -- ^ uart_tx, and what the host has sent.
host = serial baud115200

-- | The 'Synthesize' annotation for a design on this board, given a module name,
-- the ports it takes besides the clock and the reset, and the ports it drives:
--
-- @
-- {-\# ANN topEntity ('basys3' "io" ('switchesPort' : 'buttonPorts') ('ports' ['ledsPort', 'displayPort'])) \#-}
-- @
--
-- @clk@ and @rst@ are prepended, because a design on this board has them first
-- and has them always.
--
-- That this can be a function at all is what makes the names below worth having.
-- GHC's stage restriction says an annotation may only mention /imported/ names,
-- so a design cannot factor its own port list out into a local definition -- but
-- a library it imports can hand it one, and the strings then live beside the pin
-- they name instead of being retyped in every design that uses it.
basys3
  :: String
  -- ^ The name of the generated HDL module, and of the directory it lands in.
  -> [PortName]
  -- ^ Inputs, after @clk@ and @rst@, in the order the arguments come.
  -> PortName
  -- ^ The output. 'ports' if there is more than one, which there usually is.
  -> TopEntity
basys3 name ins out = Synthesize
  { t_name   = name
  , t_inputs = clockPort : resetPort : ins
  , t_output = out
  }

-- | Several ports where the design has one value: a tuple of pins, or a record
-- like 'Display'.
--
-- The empty product name is what keeps them flat. @'PortProduct' "led"@ would
-- prefix every port inside it, and Clash takes the field names of a record for
-- nothing -- unnamed, a 'Display' comes out as @result_0@, @result_1@,
-- @result_2@, which no constraints file is going to match.
ports :: [PortName] -> PortName
ports = PortProduct ""

-- | The 100 MHz oscillator on pin W5.
clockPort :: PortName
clockPort = PortName "clk"

-- | btnC, pin U18, active high. 'onBoard' is what debounces it.
resetPort :: PortName
resetPort = PortName "rst"

-- | The 16 LEDs: 'Leds'.
ledsPort :: PortName
ledsPort = PortName "led"

-- | The display's three pins, in the order 'Display' names them. Nested inside
-- the design's output 'ports' it still comes out flat, as @seg@, @an@ and @dp@.
displayPort :: PortName
displayPort = ports [PortName "seg", PortName "an", PortName "dp"]

-- | The 16 slide switches: 'Switches'.
switchesPort :: PortName
switchesPort = PortName "sw"

-- | The four outer push buttons in the order a design that takes all of them
-- should take them: up, down, left, right. Reading order for the two that count,
-- which is how "Io" spells its arguments.
buttonPorts :: [PortName]
buttonPorts = [btnUPort, btnDPort, btnLPort, btnRPort]

-- | btnU, pin T18.
btnUPort :: PortName
btnUPort = PortName "btnU"

-- | btnD, pin U17.
btnDPort :: PortName
btnDPort = PortName "btnD"

-- | btnL, pin W19.
btnLPort :: PortName
btnLPort = PortName "btnL"

-- | btnR, pin T17.
btnRPort :: PortName
btnRPort = PortName "btnR"

-- | The line from the host, pin B18. An input: the board receives on it.
uartRxPort :: PortName
uartRxPort = PortName "uart_rx"

-- | The line to the host, pin A18.
uartTxPort :: PortName
uartTxPort = PortName "uart_tx"

-- | The VGA connector's five ports, in the order 'Vga' names them: the three
-- four-bit colour channels and the two syncs. Flat, as @vga_red@, @vga_green@,
-- @vga_blue@, @vga_hsync@, @vga_vsync@, which is what @constraints\/Basys3-Vga.xdc@
-- expects.
--
-- Unverified, unlike every other name here: no design in this repo drives these
-- ports, so nothing has ever made Clash emit them and nothing has matched them
-- against the constraints file. A port with no constraint fails late, in nextpnr's
-- FASM step; the first design to call 'screen' is what finds out.
vgaPort :: PortName
vgaPort = ports [ PortName "vga_red"
                , PortName "vga_green"
                , PortName "vga_blue"
                , PortName "vga_hsync"
                , PortName "vga_vsync"
                ]
