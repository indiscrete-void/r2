module Polysemy.Socket (Socket (..), accept, send, receive, close, socketToIO) where

import Control.Monad
import Data.ByteString
import Network.Socket qualified as Network
import Network.Socket.ByteString qualified as Network
import Polysemy hiding (send)

data Socket s m a where
  Send :: s -> ByteString -> Socket s m ()
  Receive :: s -> Socket s m ByteString
  Accept :: Socket s m s
  Close :: s -> Socket s m ()

makeSem ''Socket

socketToIO :: (Member (Embed IO) r) => Int -> Network.Socket -> InterpreterFor (Socket Network.Socket) r
socketToIO bufferSize srv = do
  interpret \case
    Accept -> embed $ fst <$> Network.accept srv
    Send s b -> embed . void $ Network.send s b
    Receive s -> embed $ Network.recv s bufferSize
    Close s -> embed $ Network.close s
