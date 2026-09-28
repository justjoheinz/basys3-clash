{-|
Making a mechanical contact -- a push button, a slide switch, a card-detect
microswitch -- safe to build logic on. Two problems, and they are separate ones:

The contact changes whenever a finger says so, not when the clock says so, so a
register sampling it can latch a level that is neither high nor low and pass that
on. 'synchronise' costs two flip-flops and makes the input a proper Boolean
before anything branches on it.

The contact also bounces: the metal makes and breaks several times over a few
hundred microseconds before it settles. Anything counting edges sees one press
as a handful. 'debounce' waits for the input to hold still.

Both are parameterised by cycle counts rather than times, because only the board
knows the clock frequency; "Basys3" supplies the numbers for this board.
-}
module Peripheral.Button
  ( synchronise
  , debounce
  , rising
  , falling
  , contact
  , bank
  ) where

import Clash.Prelude

-- | Two registers in this domain, which is the standard cure for an input that
-- changes independently of the clock. One register is not enough: it can settle
-- to an undecided level and fan that out to logic that then disagrees with
-- itself about what the input was.
synchronise :: (HiddenClockResetEnable dom, NFDataX a) => a -> Signal dom a -> Signal dom a
synchronise initial = register initial . register initial

-- | Pass a change through only once the input has read the same for
-- @limit + 1@ cycles. A glitch shorter than that never reaches the output.
--
-- Deliberately not one debouncer per bit: a single counter watches the whole
-- value, and any change at all restarts it. For contacts a human operates one
-- at a time that is the same behaviour for a fraction of the logic, and it is
-- what makes 'bank' affordable for sixteen switches.
debounce
  :: forall a dom
   . (HiddenClockResetEnable dom, NFDataX a, Eq a)
  => a
  -- ^ What the output reads before anything has settled.
  -> Unsigned 32
  -- ^ Cycles the input must hold still, minus one.
  -> Signal dom a
  -> Signal dom a
debounce initial limit = moore step out (initial, initial, 0)
 where
  out (stable, _, _) = stable

  step :: (a, a, Unsigned 32) -> a -> (a, a, Unsigned 32)
  step (stable, seen, n) inp
    -- Moved again: start the wait over from this value.
    | inp /= seen = (stable, inp, 0)
    -- Held still long enough. The count saturates rather than wrapping, so a
    -- contact left alone does not re-announce itself every limit cycles.
    | n == limit  = (inp, inp, n)
    | otherwise   = (stable, seen, n + 1)

-- | True for exactly one cycle, on each transition from False to True.
rising :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom Bool
rising s = s .&&. (not <$> register False s)

-- | True for exactly one cycle, on each transition from True to False.
falling :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom Bool
falling s = (not <$> s) .&&. register False s

-- | The whole chain for one contact: synchronise, debounce, and report both the
-- steady level and a one-cycle pulse when it goes active.
--
-- Which direction is active is the caller's business. A button wired to read
-- high when pressed hands the pin straight in; one wired the other way inverts
-- it first, and then the pulse still means "pressed".
contact
  :: HiddenClockResetEnable dom
  => Unsigned 32
  -- ^ Cycles the contact must hold still, minus one.
  -> Signal dom Bit
  -> (Signal dom Bool, Signal dom Bool)
  -- ^ The steady level, and one cycle per activation.
contact settle raw = (level, rising level)
 where
  level = debounce False settle (bitToBool <$> synchronise low raw)

-- | 'contact' for a whole bank of them, sharing one counter: the bank reads as
-- it was last seen until every bit has held still, then updates together. Meant
-- for switches, where what matters is the level rather than the edge.
bank
  :: (HiddenClockResetEnable dom, KnownNat n)
  => Unsigned 32
  -- ^ Cycles the bank must hold still, minus one.
  -> Signal dom (BitVector n)
  -> Signal dom (BitVector n)
bank settle = debounce 0 settle . synchronise 0
