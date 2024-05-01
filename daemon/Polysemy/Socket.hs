module Polysemy.Socket (Socket, accept, scopedSockToIO) where

import Network.Socket qualified as Network
import Polysemy hiding (send)
import Polysemy.Bundle
import Polysemy.Scoped
import Polysemy.ScopedBundle (runScopedBundle_)
import Polysemy.Transport
import System.IO

type SocketEffects = ByteInputWithEOF ': ByteOutput ': Close ': '[]

type Socket = Bundle SocketEffects

bundleSockEffects :: (Member Socket r) => InterpretersFor SocketEffects r
bundleSockEffects =
  sendBundle @Close @SocketEffects
    . sendBundle @ByteOutput @SocketEffects
    . sendBundle @ByteInputWithEOF @SocketEffects

accept :: (Member (Scoped_ Socket) r) => InterpretersFor SocketEffects r
accept = scoped_ . bundleSockEffects . insertAt @3 @'[Socket]

-- intentionally doesn't close Socket after leaving scope to allow for concurrency
-- bonus: it's only (Embed IO) and not full (Final IO)
scopedSockToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpreterFor (Scoped_ Socket) r
scopedSockToIO bufferSize server = runScopedBundle_ go
  where
    go :: (Member (Embed IO) r) => InterpretersFor SocketEffects r
    go m = do
      (sock, _) <- embed $ Network.accept server
      sockToIO bufferSize sock m

sockToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpretersFor SocketEffects r
sockToIO bufferSize sock m = do
  h <- embed $ Network.socketToHandle sock ReadWriteMode
  closeToIO h . outputToIO h . inputToIO bufferSize h $ m
