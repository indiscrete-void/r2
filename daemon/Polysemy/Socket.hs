module Polysemy.Socket
  ( SocketEffects,
    Socket,
    acceptSock,
    sendToSock,
    recvFromSock,
    closeSock,
    handleClient,
    ioToSock,
    iToSock,
    oToSock,
    closeToSock,
    sockToIO,
    unserializeSock,
  )
where

import Control.Monad
import Data.ByteString
import Data.Serialize hiding (Fail)
import Network.Socket qualified as IO
import Network.Socket.ByteString qualified as IO
import Polysemy hiding (send)
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Transport
import Transport.Maybe

type SocketEffects i o = InputWithEOF i ': Output o ': Close ': '[]

data Socket i o s m a where
  AcceptSock :: Socket i o s m s
  SendToSock :: s -> o -> Socket i o s m ()
  RecvFromSock :: s -> Socket i o s m (Maybe i)
  CloseSock :: s -> Socket i o s m ()

makeSem ''Socket

handleClient :: (Member (Socket i o s) r, Member Async r) => (s -> Sem r a) -> Sem r a
handleClient f = forever $ acceptSock >>= async . f

unserializeSock :: forall i o s r. (Serialize i, Serialize o, Member Decoder r, Member Fail r, Member (Socket ByteString ByteString s) r) => InterpreterFor (Socket i o s) r
unserializeSock = interpret \case
  AcceptSock -> acceptSock
  SendToSock s o -> ioToSock s . serializeOutput @o $ output o
  RecvFromSock s -> ioToSock s . deserializeInput @i $ input
  CloseSock s -> closeSock s

ioToSock :: (Member (Socket i o s) r) => s -> InterpretersFor (SocketEffects i o) r
ioToSock s = closeToSock s . oToSock s . iToSock s

iToSock :: (Member (Socket i o s) r) => s -> InterpreterFor (InputWithEOF i) r
iToSock s = interpret \case Input -> recvFromSock s

oToSock :: (Member (Socket i o s) r) => s -> InterpreterFor (Output o) r
oToSock s = interpret \case Output str -> sendToSock s str

closeToSock :: (Member (Socket i o s) r) => s -> InterpreterFor Close r
closeToSock s = interpret \case Close -> closeSock s

sockToIO :: (Member (Embed IO) r) => Int -> Int -> IO.Socket -> InterpreterFor (Socket ByteString ByteString IO.Socket) r
sockToIO bufferSize timeout server = interpret \case
  AcceptSock -> embed $ fst <$> IO.accept server
  SendToSock s o -> embed $ IO.sendAll s o
  RecvFromSock s -> embed $ eofToNothing <$> IO.recv s bufferSize
  CloseSock s -> embed $ IO.gracefulClose s timeout
