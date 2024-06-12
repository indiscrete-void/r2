module Polysemy.Conc.Input (inputConc, runInputConc) where

import Data.List.Extra
import Polysemy
import Polysemy.Conc
import Polysemy.State
import Polysemy.Transport

type ConcurrentInput i = '[Input i, State [i], State Int, Lock]

inputConc :: (Members (ConcurrentInput i) r) => Sem r i
inputConc = lockOr (lock goRead) goWrite <* modify (+ 1)
  where
    goWrite = do
      i <- input
      modify (<> [i])
      pure i
    goRead = do
      buf <- get
      index <- get
      maybe inputConc pure $
        buf !? index

runInputConc :: (Members '[Input i, State [i], Lock] r) => InterpretersFor '[Input i, State Int] r
runInputConc = evalState 0 . interpret \case Input -> inputConc
