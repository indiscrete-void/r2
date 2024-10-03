module Pnet.Daemon.Node (pnetnd) where

import Data.ByteString (ByteString)
import Pnet.Routing
import Polysemy
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport

ping :: ByteString
ping = "ping"

pnetnd :: (Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r, Member Trace r, Member Fail r) => Sem r ()
pnetnd = traceTagged "pnetnd" . traceTagged "r2 ping" $ runR2 selfAddr go >> close
  where
    go =
      (output ping >> trace (show ping))
        >> (inputOrFail >>= trace . show)
