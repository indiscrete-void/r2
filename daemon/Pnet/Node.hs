module Pnet.Node
  ( pnetnd,
    pnetnd',
  )
where

import Data.ByteString
import Pnet.Routing
import Polysemy hiding (send)
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport

ping :: ByteString
ping = "ping"

pnetnd :: (Members (TransportEffects RoutedFrom RouteTo) r, Member Trace r, Member Fail r) => Sem r ()
pnetnd = runR2 selfAddr go >> close
  where
    go =
      (output ping >> traceTagged "pnetnd: r2 ping" (show ping))
        >> (inputOrFail >>= traceTagged "pnetnd: r2 ping" . show)

pnetnd' :: (Members (TransportEffects ByteString ByteString) r, Member Trace r, Member Fail r) => Sem r ()
pnetnd' = runUnserialized pnetnd
  where
    runUnserialized :: (Members '[InputWithEOF ByteString, Output ByteString] r, Member Fail r) => InterpretersFor '[InputWithEOF RoutedFrom, Output RouteTo, Decoder] r
    runUnserialized = runDecoder . serializeOutput @RouteTo . deserializeInput @RoutedFrom
