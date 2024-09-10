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
pnetnd = runR2 selfAddr go >> close
  where
    go =
      (output ping >> traceTagged "pnetnd: r2 ping" (show ping))
        >> (inputOrFail >>= traceTagged "pnetnd: r2 ping" . show)
