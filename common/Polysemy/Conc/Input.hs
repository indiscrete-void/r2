module Polysemy.Conc.Input (inputConc, runInputConc) where

import Polysemy
import Polysemy.Transport

inputConc :: (Member (Input i) r) => Sem r i
inputConc = _

runInputConc :: (Member (Input i) r) => InterpreterFor (Input i) r
runInputConc = interpret \case Input -> inputConc
