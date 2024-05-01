module Pnet.Polysemy.Trace (traceTagged) where

import Polysemy
import Polysemy.Trace

traceTagged :: (Member Trace r) => String -> String -> Sem r ()
traceTagged a b = trace (a <> ": " <> b)
