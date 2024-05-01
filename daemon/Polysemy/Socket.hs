module Polysemy.Socket (Socket (..), accept, send, receive, close, socketToIO, transportToSocket) where

import Control.Monad
import Data.ByteString
import Network.Socket qualified as Network
import Network.Socket.ByteString qualified as Network
import Polysemy hiding (send)
import Polysemy.Input
import Polysemy.Output

data Socket s m a where
  Send :: s -> ByteString -> Socket s m ()
  Receive :: s -> Socket s m ByteString
  Accept :: Socket s m s
  Close :: s -> Socket s m ()

makeSem ''Socket

transportToSocket :: forall s r1. (Member (Socket s) r1) => s -> InterpretersFor (Input ByteString ': Output ByteString ': '[]) r1
transportToSocket s = outputToSocket . inputToSocket
  where
    inputToSocket :: (Member (Socket s) r2) => InterpreterFor (Input ByteString) r2
    inputToSocket = interpret \case
      Input -> receive s
    outputToSocket :: (Member (Socket s) r2) => InterpreterFor (Output ByteString) r2
    outputToSocket = interpret \case
      Output str -> send s str

socketToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpreterFor (Socket Network.Socket) r
socketToIO bufferSize srv = do
  interpret \case
    Accept -> embed $ fst <$> Network.accept srv
    Send s b -> embed . void $ Network.send s b
    Receive s -> embed $ Network.recv s bufferSize
    Close s -> embed $ Network.close s
