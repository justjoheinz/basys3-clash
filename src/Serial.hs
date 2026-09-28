{-|
The host link as one thing you talk to, in the spirit of Arduino's @Serial@.

@
(uartOut, heard) = 'serial' 'Basys3.baud115200' rxPin
                    ('say' greeting 'atReset' \`'before'\` 'report' word count)
@

That is the whole transmit side of a design: a greeting once, the counter
whenever it changes, and nothing said about who owns the transmitter or what it
is doing this cycle.

What is worth borrowing from Arduino is the shape of the front door -- one named
link, a print that takes a value rather than bytes, and no thought spent on
arbitration. What cannot be borrowed is the part of @Serial.print@ that makes it
easy in software:

  * __Nothing blocks.__ There is no call to return from. A value goes out over
    the hundreds of microseconds its bytes take, and the design carries on
    meanwhile -- which is why 'report' watches a signal instead of being called.
  * __Nothing is buffered.__ @Serial.print@ hands bytes to a queue. Here a
    'Source' holds its own place in its own spelling, so a value that changes
    faster than the wire coalesces into one later report rather than filling a
    FIFO. Where a queue is genuinely wanted, it is a separate 'Source'.
  * __Each use is its own circuit.__ Two 'report's are two sequencers, not two
    calls to a shared one. They are cheap -- a few dozen flip-flops -- but they
    are not free, and a loop cannot make one.

The @Serial@ name is on purpose: it is the front door, so it is where somebody
will look. Like "Ascii" it sits outside the @Protocol@, @Peripheral@ and @Pmod@
namespaces, and for the same reason -- it is not a wire, a class of device or a
Pmod, but the convenience layer over "Protocol.UART" and "Ascii". Pushing it into
@Protocol@ would make a framing module depend on text.
-}
module Serial
  ( -- * Talking to the host
    serial
  , transmit
    -- * Things with bytes to say
  , Source
  , say
  , report
  , silent
  , before
  , atReset
    -- * What came back
  , UartRx (..)
  , decoded
  ) where

import Clash.Prelude

import Control.Monad ((>=>))

import Protocol.UART (UartRx (..), UartTx (..), uartRx, uartTx)

-- | Something with bytes to hand over, one per cycle its offer is accepted.
--
-- The argument is whether a byte offered this cycle would be taken; the results
-- are the byte on offer and whether there is more to come. A source with nothing
-- to say offers 'Nothing' and says 'False', so "busy" and "offering" mean the
-- same thing.
--
-- __The contract, and the one way to break it:__ whether there is more to come
-- must not depend combinationally on whether this cycle's byte was taken. It has
-- to come out of a register. 'say' and 'report' are both Moore machines, so both
-- hold to that; a Mealy source would turn 'before' into a combinational loop and
-- Clash would report it as one.
type Source dom =
  Signal dom Bool
  -> (Signal dom (Maybe (BitVector 8)), Signal dom Bool)

-- | Nothing to say, ever. The identity for 'before', and a useful stand-in while
-- a design's other half is being written.
silent :: Source dom
silent _ = (pure Nothing, pure False)

-- | Two sources, one transmitter, the left one winning: @greeting \`before\`
-- reports@.
--
-- The one on the right is simply told the transmitter is busy until the one on
-- the left runs out, which is enough because a 'Source' holds its byte until the
-- offer is taken. Nothing is lost and nothing is queued.
--
-- Associative, with 'silent' as the identity, so any number of clients chain in
-- priority order without anybody writing a priority tree:
--
-- @
-- 'foldr' 'before' 'silent' [urgent, chatty, background]
-- @
before :: Source dom -> Source dom -> Source dom
before urgent patient taken = (mux busy offered waiting, (||) <$> busy <*> holding)
 where
  (offered, busy)    = urgent taken
  (waiting, holding) = patient ((&&) <$> taken <*> (not <$> busy))

-- | True for the first cycle out of reset and never again, so a design can speak
-- unprompted: @'say' greeting 'atReset'@.
--
-- One cycle is all 'say' needs, and one cycle is what makes it a greeting rather
-- than a stutter -- a trigger held high would say the string once anyway, but
-- only because 'say' ignores it while talking.
atReset :: HiddenClockResetEnable dom => Signal dom Bool
atReset = register True (pure False)

-- | The state of one 'say'. No copy of the string: it is a constant, so the
-- index into it is the only thing that has to be remembered.
data Saying n = Saying
  { atIndex :: Index n
    -- ^ The byte to offer next.
  , talking :: Bool
    -- ^ False when the whole string has been handed over.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Hand a fixed string over, one byte per cycle the transmitter says it will
-- take one.
--
-- The string is a constant, so it costs LUTs and not memory. That is the right
-- trade for a greeting; a few hundred bytes is where block RAM and @MemBlob@
-- start to be the better answer instead.
say
  :: forall dom n
   . (HiddenClockResetEnable dom, KnownNat n, 1 <= n)
  => Vec n (BitVector 8)
  -- ^ What to say. Constant, so no address arrives from anywhere and the whole
  -- thing collapses into a mux tree.
  -> Signal dom Bool
  -- ^ Start. Ignored while this 'say' is still talking, so a held button says
  -- the string once rather than continuously.
  -> Source dom
say what start taken = unbundle (moore step out initial (bundle (start, taken)))
 where
  -- Annotated because nothing else in 'step' or 'out' pins the state's length
  -- to the string's.
  initial = Saying { atIndex = 0, talking = False } :: Saying n

  out s
    | talking s = (Just (what !! atIndex s), True)
    | otherwise = (Nothing, False)

  -- Moore, so the byte on offer follows a register and cannot glitch, and so
  -- 'talking' is honest about the cycle the last byte is handed over rather
  -- than a cycle early.
  step s (begin, accepted)
    | not (talking s)       = if begin then s { talking = True } else s
    | not accepted          = s
    | atIndex s == maxBound = Saying { atIndex = 0, talking = False }
    | otherwise             = s { atIndex = atIndex s + 1 }

-- | The state of one 'report'. 'told' is both halves of the job at once: the
-- value the host was last told about, and -- while 'telling' -- the value being
-- spelt out right now. They are the same thing, because a report is started by
-- deciding to tell somebody a value, so nothing has to be frozen separately.
data Reporting a n = Reporting
  { told    :: Maybe a
    -- ^ 'Nothing' until the first report, which no value is equal to, so one
    -- report goes out unprompted after reset whatever the value happens to be.
  , atByte  :: Index n
    -- ^ The byte of the spelling to offer next.
  , telling :: Bool
    -- ^ False when there is nothing to say.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | Spell a value out to the host whenever it changes.
--
-- @
-- 'report' ('line' . 'hex') count :: 'Source' dom
-- @
--
-- Three things follow from watching the value rather than being told to print
-- it, and all three are what makes this usable at 115200 baud:
--
--   * __The value is frozen for the length of a report.__ Six bytes always
--     describe one number, even if the value moves while they are leaving.
--   * __Changes coalesce; they are not dropped.__ A change during a report
--     schedules exactly one more report afterwards, however many changes there
--     were. Pasting into a terminal delivers a byte every ten bit periods and a
--     six-byte report takes sixty, so changes /will/ be missed -- and the host
--     still ends up with the value the board actually holds, which is the
--     property that matters.
--   * __One report goes out unprompted after reset__, so a link can be checked
--     without touching the board.
--
-- The spelling is combinational over a live value, so it becomes a mux tree the
-- width of the format: fine for the handful of bytes a number takes, and the
-- same caveat 'say' carries applies from a few hundred bytes up.
report
  :: forall dom n a
   . (HiddenClockResetEnable dom, KnownNat n, 1 <= n, Eq a, NFDataX a)
  => (a -> Vec n (BitVector 8))
  -- ^ How to spell it. 'Ascii.line' and 'Ascii.hex' compose into most of these.
  -> Signal dom a
  -- ^ What to watch.
  -> Source dom
report spell value taken = unbundle (moore step out initial (bundle (value, taken)))
 where
  -- Annotated for the reason 'say''s initial state is: nothing else ties the
  -- index to the length of the spelling.
  initial = Reporting { told = Nothing, atByte = 0, telling = False } :: Reporting a n

  -- 'told' is always 'Just' while 'telling', so the second guard cannot fail;
  -- matching on it is how the value being spelt is got at without a default to
  -- stand in for one that does not exist yet.
  out s
    | telling s, Just v <- told s = (Just (spell v !! atByte s), True)
    | otherwise                   = (Nothing, False)

  step s (v, accepted)
    -- Nothing to say. Comparing against what the host was last told, rather
    -- than watching for the change as it happens, is what makes this coalesce
    -- instead of drop.
    | not (telling s) = if told s == Just v
                        then s
                        else Reporting { told = Just v, atByte = 0, telling = True }
    -- Mid-report, waiting for the transmitter.
    | not accepted    = s
    -- The last byte has been handed over. 'told' stays put: it is now the record
    -- of what the host knows.
    | atByte s == maxBound = s { atByte = 0, telling = False }
    | otherwise            = s { atByte = atByte s + 1 }

-- | The transmitter with its own feedback loop closed, which is the part nobody
-- should have to write twice: a 'Source' is offered a byte's worth of room
-- exactly when the transmitter has some.
driving
  :: forall dom
   . HiddenClockResetEnable dom
  => Unsigned 16
  -> Source dom
  -> Signal dom UartTx
driving period src = tx
 where
  tx         = uartTx period offer
  (offer, _) = src (txIdle <$> tx)

-- | The host link, both directions, wired up: give it a bit period, the receive
-- pin and something to say, and it hands back the transmit pin and everything
-- heard.
--
-- The whole 'UartRx' comes back rather than just the byte, because a framing
-- error is worth a light: it is what a terminal set to the wrong speed looks
-- like from this end, and the alternative symptom is silence.
serial
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ Clock cycles per bit, minus one; 'Basys3.baud115200' on the board.
  -> Signal dom Bit
  -- ^ The receive pin, straight from the pad.
  -> Source dom
  -- ^ What to say, however many clients that is: see 'before'.
  -> (Signal dom Bit, Signal dom UartRx)
  -- ^ The transmit pin, and what the host has sent.
serial period rxPin src = (txLine <$> driving period src, uartRx period rxPin)

-- | What the host asked for, if anything: give it the meaning of one byte and
-- what came back from 'serial'.
--
-- @
-- typed = 'decoded' typedAs heard   -- 'Signal' dom ('Maybe' Typed)
-- @
--
-- The two ways of getting 'Nothing' collapse on purpose -- no byte arrived this
-- cycle, or one did and it meant nothing to this design -- because both want the
-- same thing done about them, which is nothing. That is what makes a request an
-- input to this cycle's update like any button press, with no state anywhere to
-- say a command is half-said: see 'Io.typedAs' for a whole vocabulary written
-- this way, and note that a command too long for one byte needs a state machine
-- of its own rather than this.
decoded
  :: (BitVector 8 -> Maybe a)
  -- ^ What one byte means. 'Nothing' for the bytes this design ignores, which is
  -- most of what a terminal sends.
  -> Signal dom UartRx
  -> Signal dom (Maybe a)
decoded meaning = fmap (rxByte >=> meaning)

-- | For a design that only talks. Builds no receiver at all, which is the
-- honest shape when there is no pin to give one.
transmit
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -> Source dom
  -> Signal dom Bit
transmit period src = txLine <$> driving period src
