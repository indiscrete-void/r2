module Polysemy.Socket
  ( SocketEffects,
    Socket,
    ByteSocketEffects,
    ByteSocket,
    accept,
    scopedSockToIO,
    unserializeScopedSock,
    handleClient,
  )
where

import Control.Monad
import Data.ByteString
import Data.Serialize
import Network.Socket qualified as Network
import Polysemy hiding (send)
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Fail
import Polysemy.Scoped
import Polysemy.ScopedBundle (runScopedBundle_)
import Polysemy.Serialize
import Polysemy.Transport
import System.IO

type SocketEffects i o = InputWithEOF i ': Output o ': Close ': '[]

type Socket i o = Bundle (SocketEffects i o)

type ByteSocketEffects = SocketEffects ByteString ByteString

type ByteSocket = Socket ByteString ByteString

bundleSockEffects :: forall i o r. (Member (Socket i o) r) => InterpretersFor (SocketEffects i o) r
bundleSockEffects =
  sendBundle @Close @(SocketEffects i o)
    . sendBundle @(Output o) @(SocketEffects i o)
    . sendBundle @(InputWithEOF i) @(SocketEffects i o)

accept :: forall i o r. (Member (Scoped_ (Socket i o)) r) => InterpretersFor (SocketEffects i o) r
accept = scoped_ . bundleSockEffects . insertAt @3 @'[Socket i o]

handleClient :: forall i o r. (Member (Scoped_ (Socket i o)) r, Member Async r) => InterpretersFor (SocketEffects i o) r
handleClient m = forever $ accept @i @o (async m)

-- intentionally doesn't close Socket after leaving scope to allow for concurrency
-- bonus: it's only (Embed IO) and not full (Final IO)
scopedSockToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpreterFor (Scoped_ (Socket ByteString ByteString)) r
scopedSockToIO bufferSize server = runScopedBundle_ go
  where
    go :: (Member (Embed IO) r) => InterpretersFor (SocketEffects ByteString ByteString) r
    go m = do
      (sock, _) <- embed $ Network.accept server
      sockToIO bufferSize sock m

unserializeScopedSock :: forall i o r. (Serialize i, Serialize o, Member Decoder r, Member Fail r, Member (Scoped_ ByteSocket) r) => InterpreterFor (Scoped_ (Socket i o)) r
unserializeScopedSock = accept @ByteString @ByteString . runScopedBundle_ @(SocketEffects i o) unserializeSock . insertAt @1 @ByteSocketEffects
  where
    unserializeSock :: (Member Decoder r', Member Fail r', Members ByteSocketEffects r') => InterpretersFor (SocketEffects i o) r'
    unserializeSock = subsume @Close . serializeOutput . deserializeInput

sockToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpretersFor ByteSocketEffects r
sockToIO bufferSize sock m = do
  h <- embed $ Network.socketToHandle sock ReadWriteMode
  closeToIO h . outputToIO h . inputToIO bufferSize h $ m
