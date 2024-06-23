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
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport

ping :: ByteString
ping = "ping"

pnetnd :: (Members (SocketEffects RoutedFrom RouteTo) r, Member Trace r, Member Fail r) => Sem r ()
pnetnd = runR2 selfAddr (output ping >> traceTagged "pnetnd: r2 ping" (show ping) >> inputOrFail >>= go) >> close
  where
    go (RoutedFrom addr maybeMsg)
      | addr == selfAddr = traceTagged "pnetnd: r2 ping" (show maybeMsg)
      | otherwise = fail "pnetnd: r2 ping: got no reply"

pnetnd' :: (Members (SocketEffects ByteString ByteString) r, Member Trace r, Member Fail r) => Sem r ()
pnetnd' = runUnserialized pnetnd
  where
    runUnserialized :: (Members '[InputWithEOF ByteString, Output ByteString] r, Member Fail r) => InterpretersFor '[InputWithEOF RoutedFrom, Output RouteTo, Decoder] r
    runUnserialized = runDecoder . serializeOutput @RouteTo . deserializeInput @RoutedFrom
