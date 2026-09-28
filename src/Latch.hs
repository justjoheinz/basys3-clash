{-|
Remembering that something happened.

Hardware reports events one cycle wide. A framing error on the serial link
("Protocol.UART"), an attempt that gave up ("Pmod.SdCard") -- each is true for
ten nanoseconds and then gone, which is invisible on an LED and invisible to a
person. Every design here wanted the same flip-flop for it, and wrote the same
line to get one:

@
faulty = 'register' False ((rxError \<$\> heard) '.||.' faulty)
@

'latch' is that line, once. The three designs that used to spell it out are
'Sketch', 'Io' and 'Sd'.

This module is unprefixed for the reason "Ascii" and "Serial" are: one register
with an obvious job is not a wire protocol, a class of device, or something you
can plug into a header. It comes in with "Basys3.Board" like everything else.
-}
module Latch
  ( latch
  ) where

import Clash.Prelude

-- | True from the first cycle its input is 'True', and for ever after.
--
-- @
-- faulty = 'latch' (rxError \<$\> heard)   -- lights a lamp and keeps it lit
-- @
--
-- Reset is the way back: it starts 'False' again, which on this board means btnC
-- clears the light. That is the whole interface on purpose -- a latch with a
-- clear input is a state machine, and a design that wants one should say so
-- rather than get one by accident.
--
-- __Not a level-sensitive latch__, despite the name. It is a flip-flop with an
-- 'or' in front of it -- one FF and one LUT -- and the name is the verb the
-- surrounding documentation already used ("latch it if it is to be displayed").
-- Nothing here is transparent, and nothing here can be inferred by mistake.
latch :: HiddenClockResetEnable dom => Signal dom Bool -> Signal dom Bool
latch it = held
 where
  held = register False (it .||. held)
