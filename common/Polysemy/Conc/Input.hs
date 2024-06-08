module Polysemy.Conc.Input (inputConc) where

import Polysemy
import Polysemy.Transport

inputConc :: (Member (Input i) r) => Sem r i
inputConc = _
