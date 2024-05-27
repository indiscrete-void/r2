module Polysemy.Socket (SocketEffects, inputToSock, outputToSock, closeToSock) where

import Control.Monad
import Network.Socket qualified as IO
import Network.Socket.ByteString qualified as IO
import Polysemy
import Polysemy.Transport
import Transport.Maybe

type SocketEffects i o = InputWithEOF i ': Output o ': Close ': '[]

inputToSock :: (Member (Embed IO) r) => Int -> IO.Socket -> InterpreterFor ByteInputWithEOF r
inputToSock bufferSize s = interpret \Input -> embed $ eofToNothing <$> IO.recv s bufferSize

outputToSock :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor ByteOutput r
outputToSock s = interpret \(Output str) -> embed . void $ IO.send s str

closeToSock :: (Member (Embed IO) r) => Int -> IO.Socket -> InterpreterFor Close r
closeToSock timeout s = interpret \Close -> embed $ IO.gracefulClose s timeout
