{-|
A single-master I2C controller, one operation at a time.

Two wires, both open drain with a pull-up resistor on them, and every device on
the bus -- this master included -- may only ever pull a line low or let go of it.
Nothing drives high, which is what lets a target answer on the same wire the
master asked on, and what makes a stuck line a hardware fault rather than a
contention. That is why 'I2cOut' reports @Low@ flags rather than pin levels:
'True' means pull this line down, 'False' means release it and let the pull-up
decide. 'openDrain' turns either into the tristate a pin wants.

The protocol, briefly:

  * a START is SDA falling while SCL is high, and a STOP is SDA rising while SCL
    is high. Those are the only two times SDA is allowed to move with SCL up;
    everywhere else it changes while SCL is low, which is what makes them
    unambiguous.
  * between them the wire carries bytes, most significant bit first, each
    followed by a ninth bit: the acknowledge. The side /receiving/ the byte
    drives it, pulling SDA low to mean "that arrived, carry on".
  * the first byte after a START is a seven-bit address and a direction bit,
    which is all 'addressFor' is.
  * a target that needs time may hold SCL down after the master has released it.
    The clock is only high when the wire is high, so the master has to watch SCL
    as well as drive it. This is clock stretching, and it is the reason
    'i2cMaster' takes SCL as an input.

START and STOP are this module's business, where "Protocol.SPI" leaves chip
select to whoever is using it. The difference is that chip select is a wire
beside the bus and says nothing about timing, while a START /is/ a particular
edge in a particular place -- a byte pipe that could not produce one would not be
speaking I2C. Hence 'I2cOp': four things a master can put on the wire, offered
one at a time, exactly as 'Protocol.SPI.spiMaster' takes one byte at a time.

A repeated START -- addressing a second thing, or turning a write into a read,
without letting go of the bus -- is the same 'Start'. The sequence it performs
releases SDA, releases SCL, then pulls SDA low, which is a fresh START from an
idle bus and a repeated one from the middle of a transaction, with no way for the
caller to pick wrong.

Fixed here, and worth parameterising if something ever needs otherwise:

  * one master, so there is no arbitration and no bus-busy check. Multi-master
    I2C means watching SDA for another master pulling it low under you, which is
    a second thing this would have to do with the SDA it already reads.
  * no timeout on a stretched clock. A master waiting for SCL waits forever, and
    the way out is reset. I2C's own answer is that a target holding SCL is a
    target that is going to let go; SMBus disagrees and specifies 35 ms, which
    would be another counter and another 'I2cReply'.
  * seven-bit addressing in 'addressFor' only. Ten-bit addressing and the general
    call are two 'Write's and a byte pipe does not need to know.

The bit period is /not/ fixed, for the reason 'Protocol.SPI.spiMaster''s SCK
period and "Protocol.UART"'s baud are not: the board wants 100 kHz and a test
bench wants a bit every dozen cycles.

Wiring it to a pin pair, which is the one part of using this that is not obvious
-- both lines are bidirectional, so both are a 'Clash.Signal.BiSignal.BiSignalIn'
read from and written to:

@
i2c :: 'HiddenClockResetEnable' dom
    => 'Clash.Signal.BiSignal.BiSignalIn' ''Clash.Signal.BiSignal.Floating' dom 1
    -> 'Clash.Signal.BiSignal.BiSignalIn' ''Clash.Signal.BiSignal.Floating' dom 1
    -> 'Signal' dom ('Maybe' 'I2cOp')
    -> ( 'Clash.Signal.BiSignal.BiSignalOut' ''Clash.Signal.BiSignal.Floating' dom 1
       , 'Clash.Signal.BiSignal.BiSignalOut' ''Clash.Signal.BiSignal.Floating' dom 1
       , 'Signal' dom 'I2cOut' )
i2c sclPin sdaPin op = (scl, sda, out)
 where
  out = 'i2cMaster' 249 op ('lsb' \<$\> 'Clash.Signal.BiSignal.readFromBiSignal' sclPin)
                           ('lsb' \<$\> 'Clash.Signal.BiSignal.readFromBiSignal' sdaPin)
  scl = 'Clash.Signal.BiSignal.writeToBiSignal' sclPin ('openDrain' . 'i2cSclLow' \<$\> out)
  sda = 'Clash.Signal.BiSignal.writeToBiSignal' sdaPin ('openDrain' . 'i2cSdaLow' \<$\> out)
@

The checks in @spec\/@ put a pretend temperature sensor on the other end of the
bus -- a real I2C target with its own address and register map, an ADT7420 as far
as the wire can tell. It is test code and lives with them rather than here, so
testing a driver of your own means a double of your own; @spec\/FakeTmp2.hs@ is
what one looks like.

The @Protocol@ namespace is for bus masters: timing and framing that everything
on the wire shares, never anything about a particular device. Its other members
are "Protocol.SPI" and "Protocol.UART". Bit order is the one thing all three
disagree about and it is worth holding in mind -- I2C and SPI send the most
significant bit first, a UART the least.
-}
module Protocol.I2C
  ( I2cOp (..)
  , I2cReply (..)
  , I2cOut (..)
  , i2cMaster
  , addressFor
  , openDrain
  ) where

import Clash.Prelude

-- | One thing a master can put on the wire. Offered to 'i2cMaster' whenever
-- 'i2cIdle' is set, and a transaction is however many of these it takes:
--
-- @
-- ['Start', 'Write' ('addressFor' 0x48 'False'), 'Write' 0x00, 'Start', 'Write' ('addressFor' 0x48 'True'), 'Read' 'True', 'Read' 'False', 'Stop']
-- @
--
-- which is the write-a-register-then-read-it shape almost every I2C part uses.
data I2cOp
  = Start
    -- ^ A START condition, or a repeated START -- the same sequence serves for
    -- both, from an idle bus or from the middle of a transaction.
  | Stop
    -- ^ A STOP condition, after which the bus is free.
  | Write (BitVector 8)
    -- ^ Send a byte, most significant bit first, and read the acknowledge the
    -- target answers with. Replies 'Acked'.
  | Read Bool
    -- ^ Receive a byte, and acknowledge it or not: 'True' means another one
    -- follows, 'False' is the NACK that tells the target this was the last.
    -- Replies 'Fetched'.
  deriving (Generic, NFDataX, Show, Eq)

-- | What an operation came to. Reported for the single cycle in which the
-- operation finishes, which is also the cycle 'i2cIdle' comes back.
data I2cReply
  = Framed
    -- ^ A 'Start' or a 'Stop' is on the wire.
  | Acked Bool
    -- ^ A 'Write' finished. 'True' if the target pulled SDA low to acknowledge
    -- it; 'False' means nobody answered, which after an address byte is how an
    -- absent device reads and is usually the point at which a sequencer gives
    -- up.
  | Fetched (BitVector 8)
    -- ^ A 'Read' finished, with the byte the target sent.
  deriving (Generic, NFDataX, Show, Eq)

-- | What the master is doing to the two lines, and what it has heard.
--
-- Neither line is a level. Both are @Low@ flags, because an open-drain device
-- has only two choices and "drive high" is not one of them: see 'openDrain'.
data I2cOut = I2cOut
  { i2cSclLow :: Bool
    -- ^ Pull SCL low. Released between the halves of a bit, and held low
    -- between operations -- so a transaction may be as leisurely as its
    -- sequencer likes without anything on the wire going wrong.
  , i2cSdaLow :: Bool
    -- ^ Pull SDA low. Released for every bit the other end drives, which is a
    -- target's acknowledge and the whole of a 'Read'.
  , i2cDone   :: Maybe I2cReply
    -- ^ 'Just' during the single cycle in which an operation completes.
  , i2cIdle   :: Bool
    -- ^ True when an operation offered to 'i2cMaster' this cycle would be
    -- accepted. The cycle an operation completes is idle too, so a consumer may
    -- see 'i2cDone' and start the next operation without a gap.
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | The first byte after a START: a seven-bit address, then the direction bit.
--
-- 'True' for a read, which is the sense the bit has on the wire -- and the
-- opposite of how it is usually named, @R\/W#@ being one of the few active-low
-- signals that is a data bit.
addressFor :: BitVector 7 -> Bool -> BitVector 8
addressFor addr forRead = addr ++# pack forRead

-- | An 'i2cSclLow' or 'i2cSdaLow' flag as a tristate drive:
-- 'Clash.Signal.BiSignal.writeToBiSignal' wants 'Nothing' for released and
-- 'Just' for driven, and the only value an open-drain output ever drives is
-- zero.
openDrain :: Bool -> Maybe (BitVector 1)
openDrain pullLow = if pullLow then Just 0 else Nothing

-- | Which operation is in flight. The bit counter lives in the constructor that
-- has one, as "Protocol.UART"'s @Phase@ and 'Pmod.SdCard.Stage' do.
data Stage
  = Resting
    -- ^ Nothing in flight, and both lines left exactly as the last operation
    -- put them.
  | Beginning
    -- ^ A START.
  | Ending
    -- ^ A STOP.
  | Shifting (Index 9)
    -- ^ Which bit of a byte is on the wire; 8 is the acknowledge.
  deriving (Generic, NFDataX, Show, Eq)

-- | Where within an operation. Each of these names the state the /bus/ is in
-- while it lasts, and the transition into it is what puts the bus there.
--
-- A byte's four are a quarter of a bit period each. A START's and a STOP's are
-- half of one, because their setup and hold times are specified as most of a
-- period and not a quarter of it: at 100 kHz a START needs SCL high for 4.7 us
-- before SDA falls and SDA low for 4.0 us before SCL follows, which is 8.7 us of
-- a 10 us bit and leaves no way to do it in quarters.
data Phase
  = Prepared
    -- ^ SDA carries the bit, SCL is low. A quarter, which is the bit's setup
    -- time.
  | Freed
    -- ^ SCL released and up. A quarter, ending at the sample point -- so SDA is
    -- read halfway through the high period rather than at either edge of it.
  | Sampled
    -- ^ The bit has been read; the rest of the high period. A quarter.
  | Pulled
    -- ^ SCL low again. A quarter, which with the next bit's 'Prepared' makes the
    -- low period as long as the high one.
  | Loosed
    -- ^ START: SDA released, SCL wherever the last operation left it. A half.
  | Risen
    -- ^ START and STOP: SCL released and up, waiting out the setup time before
    -- SDA moves. A half.
  | Marked
    -- ^ START: SDA low with SCL still high -- the START condition itself, held
    -- for a half.
  | Dropped
    -- ^ START: SCL low, ready for the first bit. A half.
  | Grounded
    -- ^ STOP: SDA low with SCL still low. A half.
  | Cleared
    -- ^ STOP: SDA released with SCL high -- the STOP condition itself, and then
    -- a half of bus-free time before anything may start again.
  deriving (Generic, NFDataX, Show, Eq)

-- | The registers: where we are, how long until the next boundary, what we are
-- doing to the two lines, and the bits either way.
data I2c = I2c
  { stage     :: Stage
  , phase     :: Phase
  , countdown :: Unsigned 16  -- ^ cycles left in this phase
  , sclLow    :: Bool
  , sdaLow    :: Bool
  , txShift   :: BitVector 8  -- ^ bits still to send, most significant first
  , rxShift   :: BitVector 8  -- ^ bits received, shifted in at the bottom
  , reading   :: Bool         -- ^ this byte is a 'Read'
  , acking    :: Bool         -- ^ and we mean to acknowledge it
  , acked     :: Bool         -- ^ the target acknowledged a 'Write'
  , replied   :: Maybe I2cReply
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @i2cMaster quarter op scl sda@ performs one 'I2cOp' at a time.
--
-- Both @scl@ and @sda@ are the lines as they read, which on real hardware is the
-- input side of the same tristate the outputs drive -- see the module header. In
-- simulation the bus is a pull-up and whatever is on it:
-- @'boolToBit' . 'not' . 'i2cSclLow'@ with nothing else pulling.
--
-- SCL comes out slightly slower than @4 * (quarter + 1)@ cycles a bit, and
-- deliberately: the high period is timed from the cycle SCL /reads/ high, not
-- from the cycle it was released, so the pull-up's rise time and the two cycles
-- of input synchronisation are added to each bit rather than stolen from it. A
-- stretched clock is the same mechanism taken to its limit.
i2cMaster
  :: HiddenClockResetEnable dom
  => Unsigned 16
  -- ^ Clock cycles per quarter bit period, minus one, so the bus runs at about
  -- @f \/ (4 * (quarter + 1))@: at 100 MHz, 249 gives 100 kHz and 61 gives
  -- 400 kHz. At least 2, since the sample point is a quarter period after SCL
  -- is released and the input synchronisers below cost two cycles of that.
  -> Signal dom (Maybe I2cOp)
  -- ^ An operation. Ignored unless 'i2cIdle' is set.
  -> Signal dom Bit
  -- ^ SCL as it reads, which is not always what the master is driving: that is
  -- the whole point of taking it.
  -> Signal dom Bit
  -- ^ SDA as it reads.
  -> Signal dom I2cOut
i2cMaster quarter op scl sda = moore step out initial (bundle (op, safe scl, safe sda))
 where
  -- Both lines are driven by every device on the bus and released by all of
  -- them, so neither has anything to do with our clock. Two registers each, for
  -- the reason "Protocol.UART"'s receiver gives: one could settle to neither
  -- level and hand half a decision to the logic behind it. High is the value a
  -- released line takes, so this is also the right thing to come out of reset
  -- believing.
  safe = register high . register high

  -- The two phase lengths, as cycles minus one.
  aQuarter = quarter
  aHalf    = 2 * quarter + 1

  initial = I2c { stage     = Resting
                , phase     = Prepared
                , countdown = 0
                , sclLow    = False
                , sdaLow    = False
                , txShift   = maxBound
                , rxShift   = 0
                , reading   = False
                , acking    = False
                , acked     = False
                , replied   = Nothing
                }

  -- Moore, not Mealy, for the reason 'Protocol.SPI.spiMaster' gives: both lines
  -- follow registers, so nothing a target does can feed through to the wire
  -- within a cycle -- which on a bus where a glitch on SDA while SCL is high is
  -- a START or a STOP is worth more here than anywhere else in this library.
  out s = I2cOut { i2cSclLow = sclLow s
                 , i2cSdaLow = sdaLow s
                 , i2cDone   = replied s
                 , i2cIdle   = stage s == Resting
                 }

  step s (offered, sclNow, sdaNow)
    -- Nothing in flight. The lines stay as the last operation left them -- SCL
    -- low between the bytes of a transaction, both released after a STOP -- so
    -- the next operation may be offered whenever its sequencer gets round to it.
    | Resting <- stage s = case offered of
        Nothing        -> quiet s
        Just Start     -> within aHalf Loosed   (quiet s) { stage   = Beginning
                                                          , sdaLow  = False }
        Just Stop      -> within aHalf Grounded (quiet s) { stage   = Ending
                                                          , sdaLow  = True }
        Just (Write b) -> prepare 0 (quiet s) { reading = False, txShift = b }
        Just (Read a)  -> prepare 0 (quiet s) { reading = True,  acking  = a }

    -- SCL has been released but has not come up: either the pull-up is still
    -- working on it or a target is holding it down to buy itself time. Either
    -- way the high period has not started, so neither has the countdown. This
    -- is the whole of clock stretching.
    | timingHigh (phase s), sclNow == low = quiet s

    -- Waiting out the rest of a phase.
    | countdown s /= 0 = quiet s { countdown = countdown s - 1 }

    -- A phase boundary, and every one of them is where the next phase's state of
    -- the bus gets put on the wire.
    | otherwise = case (stage s, phase s) of
        -- A START: SDA up, SCL up, SDA down -- the condition -- then SCL down.
        -- From an idle bus the first two change nothing, which is exactly why
        -- this doubles as a repeated START.
        (Beginning, Loosed)    -> within aHalf Risen   quieted { sclLow = False }
        (Beginning, Risen)     -> within aHalf Marked  quieted { sdaLow = True }
        (Beginning, Marked)    -> within aHalf Dropped quieted { sclLow = True }
        (Beginning, Dropped)   -> framed quieted

        -- A STOP: SDA down while SCL still is, SCL up, then SDA up -- the
        -- condition. What follows is bus-free time and needs no state of its
        -- own: 'Resting' after a STOP is a released bus, and a 'Start' offered
        -- immediately spends its own first half period doing nothing.
        (Ending, Grounded)     -> within aHalf Risen   quieted { sclLow = False }
        (Ending, Risen)        -> within aHalf Cleared quieted { sdaLow = False }
        (Ending, Cleared)      -> framed quieted

        -- One bit, whichever end is driving it.
        (Shifting _, Prepared) -> within aQuarter Freed   quieted { sclLow = False }
        (Shifting i, Freed)    -> within aQuarter Sampled (heard i quieted)
        (Shifting _, Sampled)  -> within aQuarter Pulled  quieted { sclLow = True }
        (Shifting i, Pulled)
          | i == maxBound      -> reported quieted
          | otherwise          -> prepare (i + 1) quieted { txShift = shiftL (txShift s) 1 }

        -- Unreachable: every 'Phase' above belongs to exactly one 'Stage', and
        -- 'Resting' never arrives here. Resting is the recovery a wedged master
        -- would want anyway.
        _                      -> quieted { stage = Resting }
   where
    quieted = quiet s

    -- Both phases in which SCL is meant to be high and is being timed. Once it
    -- is up it is not checked again: a target that pulls SCL back down inside a
    -- high period is not doing I2C.
    timingHigh p = p == Freed || p == Risen

    -- Every report lasts a single cycle, so every branch clears the last one.
    quiet t = t { replied = Nothing }

    within n p t = t { phase = p, countdown = n }

    -- Start bit @i@. SCL is low throughout 'Prepared', so this is where SDA is
    -- allowed to move, and the only place it does outside a START or a STOP.
    prepare i t = (within aQuarter Prepared t) { stage  = Shifting i
                                              , sdaLow = drive i t
                                              }

    -- What SDA does for bit @i@: nothing at all for a bit the other end drives,
    -- otherwise low for a zero and released for a one. The ninth bit is the
    -- acknowledge, and it is ours only when we are the one reading.
    drive i t
      | i == maxBound = reading t && acking t
      | reading t     = False
      | otherwise     = msb (txShift t) == low

    -- Halfway through the high period, which is where the bit is. A read
    -- collects it; a write's ninth bit is the target saying it heard us, and
    -- silence on an open-drain line reads high, so no answer is no
    -- acknowledgement.
    heard i t
      | i == maxBound = t { acked   = sdaNow == low }
      | otherwise     = t { rxShift = shiftL (rxShift t) 1 .|. zeroExtend (pack sdaNow) }

    framed t = (rest t) { replied = Just Framed }

    reported t = (rest t) { replied = Just reply }
     where
      reply | reading t = Fetched (rxShift t)
            | otherwise = Acked (acked t)

    rest t = t { stage = Resting }
