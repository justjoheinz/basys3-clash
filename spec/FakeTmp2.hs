{-|
A pretend temperature sensor: enough of an Analog Devices ADT7420 -- the part on
a Digilent Pmod TMP2 -- to drive "Protocol.I2C" through a whole transaction
inside @stack test@, with no hardware and no HDL simulator.

It is a real I2C target, watching the same two wires a chip does and moving SDA
on the same edges, so a test that uses it covers the bit-level timing of
"Protocol.I2C" as well as whatever sits above it. In particular it does the one
thing no amount of staring at a master's outputs can check: it answers only to
its own address, and only in the acknowledge slot, and only after the direction
bit said it should.

What it models, because these are the parts a driver has to get right:

  * the seven-bit address and the direction bit, and silence when the address is
    somebody else's -- which on an open-drain line is how an absent part
    announces itself.
  * the address pointer register, written as the first byte of a write and
    surviving a STOP, which is what makes "write the pointer, then read" the
    shape every I2C part in the world uses.
  * the pointer stepping on for each byte, so a two-byte read comes back as the
    high and low halves of one 16-bit register rather than the same byte twice.
  * the acknowledge in both directions: it pulls SDA low for every byte written
    to it, and it watches the master's acknowledge of every byte it sends. A NACK
    stops it talking, which matters more than it sounds -- a target that kept
    going would hold SDA down across the STOP and the transaction would never
    end.

The register map, as far as this goes. Everything is a byte at a byte address,
and the 16-bit registers are a high half and a low half at consecutive ones:

  * @0x00@ and @0x01@, the temperature, which is the 'Signal' handed in, encoded
    the way the part's default 13-bit mode encodes it -- see 'reading';
  * @0x02@, the status: the three alarm flags, and always ready;
  * @0x03@, the configuration, which is writable and remembered and acted on by
    nothing;
  * @0x04@ to @0x09@, the @T_HIGH@, @T_LOW@ and @T_CRIT@ setpoints, read-only at
    their reset values -- 'highSet' and the two beside it;
  * @0x0A@, @T_HYST@, read-only at five degrees;
  * @0x0B@, the ID: 'tmp2Id', which is what a driver identifies the part with;
  * anything else reads as zero.

What it is not is a model of a part misbehaving. It never stretches the clock --
the real one does not either, and @spec\/@ has a separate stretcher for that --
it converts instantly, it is always ready, and its configuration register is
storage rather than a mode. Nor is it the whole ADT7420: 16-bit mode, the
one-shot and SPS conversion modes, the @INT@ and @CT@ pins, the hysteresis and
the fault queue, and the software reset at @0x2F@ are all missing. Add the one
you need; the register map is a single @case@.

__Why this lives in @spec\/@__ rather than under @Pmod.@ with the real drivers: it
is test code. A library has no business shipping a double of a part no design
here contains, and being ordinary synthesisable Clash does not make it something a
user of this library wants to link against. What that costs is worth stating: it
is visible only to the suite in this directory, so anybody writing a @Pmod.Tmp2@
driver against "Protocol.I2C" has to copy it to test one -- the same trade @check@
and @frame@ already make across the package boundary.
-}
module FakeTmp2
  ( fakeTmp2
  , tmp2Address
  , tmp2Id
  , celsius
  , reading
  , highSet
  , lowSet
  , critSet
  ) where

import Clash.Prelude

-- | The address the Pmod TMP2 comes set to.
--
-- The ADT7420 has two address pins and so four addresses, @0x48@ to @0x4B@; the
-- Pmod brings them out as a jumper block. That is why 'fakeTmp2' takes the
-- address rather than knowing it -- and why two of them on one bus is a thing a
-- test can do.
tmp2Address :: BitVector 7
tmp2Address = 0x4B

-- | What register @0x0B@ reads as, on every ADT7420 ever made. A driver that
-- reads this and gets something else is looking at an empty header, a different
-- part, or its own bit order.
tmp2Id :: BitVector 8
tmp2Id = 0xCB

-- | A temperature in the sixteenths of a degree the part measures in, which is
-- what 'fakeTmp2' wants and what 'reading' gives back.
--
-- @'celsius' 23 8@ is 23.5 °C. Both parts carry the sign, so -10.5 °C is
-- @'celsius' (-10) (-8)@: there is no sensible reading of a positive fraction of
-- a negative degree, and this way the arithmetic is the same either side of zero.
--
-- The register holds thirteen bits of this, so it runs out somewhere past 255 °C
-- in one direction and -256 °C in the other, both of which are well outside what
-- the part will survive.
celsius
  :: Signed 16
  -- ^ Whole degrees.
  -> Signed 16
  -- ^ Sixteenths of one, with the same sign.
  -> Signed 16
celsius whole parts = whole * 16 + parts

-- | The temperature the two bytes of register @0x00@ mean, in the sixteenths
-- 'celsius' counts: the top thirteen bits of the pair, signed.
--
-- This is the whole of what a driver does with a reading, and the reason the
-- bottom three bits go: in the part's default mode they are not temperature at
-- all but the three alarm flags, and a sixteenth of a degree is the resolution
-- rather than a rounding.
--
-- @
-- 'reading' hi lo == temperature   -- for the @temperature@ 'fakeTmp2' was given
-- @
reading
  :: BitVector 8
  -- ^ Register @0x00@, the high half.
  -> BitVector 8
  -- ^ Register @0x01@, the low half.
  -> Signed 16
reading hi lo = shiftR (unpack (hi ++# lo)) 3

-- | The part's reset setpoints, in sixteenths of a degree: @T_HIGH@ 64 °C,
-- @T_LOW@ 10 °C, @T_CRIT@ 147 °C.
--
-- Read-only here, which is what makes them worth naming: the alarm flags below
-- are computed against these, so the way to see a flag set is to report a
-- temperature outside them.
highSet, lowSet, critSet :: Signed 16
highSet = celsius 64 0
lowSet  = celsius 10 0
critSet = celsius 147 0

-- | Where the part is in a transaction, and what it is holding.
--
-- The address pointer and the configuration register are the two things that
-- outlive a transaction, which is the whole point of them.
data Tmp2 = Tmp2
  { position :: Index 9       -- ^ bit within the byte, most significant first; 8
                              --   is the acknowledge
  , byteNo   :: Unsigned 4    -- ^ bytes since the START; 0 is the address byte
  , mine     :: Bool          -- ^ the address matched, so this one is ours
  , sending  :: Bool          -- ^ and it asked for a read
  , rxShift  :: BitVector 8   -- ^ the byte arriving, shifted in at the bottom
  , txShift  :: BitVector 8   -- ^ the byte leaving, most significant bit out
  , pointer  :: BitVector 8   -- ^ the address pointer register
  , config   :: BitVector 8   -- ^ register @0x03@
  , pulling  :: Bool          -- ^ SDA held low
  , sclWas   :: Bit
  , sdaWas   :: Bit
  }
  deriving (Generic, NFDataX, Show, Eq)

-- | @fakeTmp2 addr temperature (scl, sda)@ pulls SDA low, or does not.
--
-- Both wires come in as they read, and only SDA goes out, because that is all a
-- part like this drives: 'Protocol.I2C.openDrain' turns the flag into a pin, and
-- on a simulated bus a line is simply high when nobody is holding it down.
--
-- Everything happens on an edge of SCL, and on the two different ones the
-- protocol assigns: SDA is driven on the falling edge, when the master's own
-- output is idle and the line is free to move, and read on the rising edge. The
-- master samples halfway through the high period, by which time this has been
-- holding the line for most of a quarter bit period, so the two never race.
fakeTmp2
  :: HiddenClockResetEnable dom
  => BitVector 7
  -- ^ The address the jumpers chose: 'tmp2Address' unless they were moved.
  -> Signal dom (Signed 16)
  -- ^ The temperature to report, in the sixteenths 'celsius' counts. Read as
  -- each byte goes on the wire, so a signal that moves mid-transaction gives a
  -- high half of one reading and a low half of another -- which is a real
  -- hazard, and not one this pretends away.
  -> Signal dom (Bit, Bit)
  -- ^ SCL and SDA as they read.
  -> Signal dom Bool
  -- ^ Pull SDA low.
fakeTmp2 addr temperature wires = moore step pulling initial (bundle (temperature, wires))
 where
  initial = Tmp2 { position = 0
                 , byteNo   = 0
                 , mine     = False
                 , sending  = False
                 , rxShift  = 0
                 , txShift  = 0
                 , pointer  = 0
                 , config   = 0
                 , pulling  = False
                 , sclWas   = high   -- an idle bus, which is both lines released
                 , sdaWas   = high
                 }

  step s (now, (scl, sda))
    -- SDA moving while SCL is up is a START, a repeated START or a STOP, and is
    -- the only thing that may happen then. All three put us back at the address
    -- byte with our hands off the wire, and none of them touches the pointer:
    -- that it survives a STOP is what makes writing it and then reading work.
    | scl == high, sclWas s == high, sda /= sdaWas s
      = seen { position = 0, byteNo = 0, mine = False, sending = False
             , pulling = False }

    -- SCL falling: our turn to put something on SDA, if this bit is ours at all.
    | sclWas s == high, scl == low = case position s of
        -- The acknowledge. Ours for every byte written to us, the address byte
        -- included; the master's for a byte we sent, and then we let go of the
        -- line so it can answer.
        8 -> seen { pulling = mine s && (byteNo s == 0 || not (sending s)) }
        -- The first bit of a byte we are sending, so there is a byte to fetch.
        -- The pointer steps on here, once per byte, which is what makes reading
        -- two of them read a whole 16-bit register.
        0 | speaking -> sends (byteAt (config s) now (pointer s))
                          seen { pointer = pointer s + 1 }
        _ | speaking -> sends (shiftL (txShift s) 1) seen
        _ -> seen { pulling = False }

    -- SCL rising: the bit is on the wire, and two of the nine are ours to read.
    | sclWas s == low, scl == high = case position s of
        -- The acknowledge of a byte we sent. High is a NACK: the master wants no
        -- more, and a target that kept talking would hold SDA down across the
        -- STOP and wedge the bus it was trying to be polite on.
        8 -> seen { position = 0
                  , byteNo   = satSucc SatBound (byteNo s)
                  , sending  = sending s && not (speaking && sda == high)
                  }
        -- The eighth bit, which completes a byte -- and it has to be acted on
        -- now, before the acknowledge, because whether we owe one depends on it.
        7 -> complete (shiftIn sda)
        _ -> seen { position = position s + 1, rxShift = shiftIn sda }

    | otherwise = seen
   where
    seen        = s { sclWas = scl, sdaWas = sda }
    speaking    = mine s && sending s && byteNo s > 0
    shiftIn b   = shiftL (rxShift s) 1 .|. zeroExtend (pack b)
    sends b t   = t { txShift = b, pulling = msb b == low }

    -- A byte arrived whole. Which one it was in the transaction is what it
    -- meant: the address, then the pointer, then something to store.
    complete got = case byteNo s of
      0 -> arrived { mine    = slice d7 d1 got == addr
                   , sending = lsb got == high
                   }
      1 | writing -> arrived { pointer = got }
      _ | writing -> arrived { pointer = pointer s + 1
                             , config  = if pointer s == 0x03 then got else config s
                             }
      _ -> arrived
     where
      arrived = seen { position = 8, rxShift = got }
      writing = mine s && not (sending s)

-- | What the register at @p@ reads as, given the configuration register and the
-- temperature. The map is in the module header.
byteAt
  :: BitVector 8
  -- ^ The configuration register, which is readable and nothing more.
  -> Signed 16
  -- ^ The temperature, in sixteenths of a degree.
  -> BitVector 8
  -- ^ The address pointer.
  -> BitVector 8
byteAt mode temperature p = case p of
  0x00 -> slice d15 d8 code
  0x01 -> slice d7  d0 code
  0x02 -> status
  0x03 -> mode
  0x04 -> slice d15 d8 (setpoint highSet)
  0x05 -> slice d7  d0 (setpoint highSet)
  0x06 -> slice d15 d8 (setpoint lowSet)
  0x07 -> slice d7  d0 (setpoint lowSet)
  0x08 -> slice d15 d8 (setpoint critSet)
  0x09 -> slice d7  d0 (setpoint critSet)
  0x0A -> 0x05          -- T_HYST, five degrees, and a whole byte of them
  0x0B -> tmp2Id
  _    -> 0
 where
  -- The part's default 13-bit mode: the reading in the top thirteen bits, and
  -- the three alarm flags in the bottom three. Which is why a sixteenth of a
  -- degree is exactly the resolution, and why 'reading' throws those bits away.
  code = setpoint temperature .|. zeroExtend alarms

  -- Whether this reading is outside each of the three setpoints. The same three
  -- bits appear in the status register four places up, where the flags are meant
  -- to be read from and where a driver in 16-bit mode would have to look.
  alarms :: BitVector 3
  alarms = (if temperature <  lowSet  then 0b001 else 0)
       .|. (if temperature >= highSet then 0b010 else 0)
       .|. (if temperature >= critSet then 0b100 else 0)

  -- Bit 7 clear is the real part saying a conversion has landed. It says so
  -- always here, where a conversion takes no time; on the ADT7420 reading the
  -- temperature sets the bit again until the next one.
  status = shiftL (zeroExtend alarms) 4

-- | A temperature in sixteenths of a degree as a 13-bit register holds it: three
-- bits up, leaving room for the flags underneath.
setpoint :: Signed 16 -> BitVector 16
setpoint t = shiftL (pack t) 3
