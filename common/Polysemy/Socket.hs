module Polysemy.Socket (SocketEffects, inputToSocket, outputToSocket, closeToSocket) where

import Control.Monad
import Network.Socket qualified as IO
import Network.Socket.ByteString qualified as IO
import Polysemy
import Polysemy.Transport
import Transport.Maybe

type SocketEffects i o = InputWithEOF i ': Output o ': Close ': '[]

inputToSocket :: (Member (Embed IO) r) => Int -> IO.Socket -> InterpreterFor ByteInputWithEOF r
inputToSocket bufferSize s = interpret \Input -> embed $ eofToNothing <$> IO.recv s bufferSize

outputToSocket :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor ByteOutput r
outputToSocket s = interpret \(Output str) -> embed . void $ IO.send s str

closeToSocket :: (Member (Embed IO) r) => Int -> IO.Socket -> InterpreterFor Close r
closeToSocket timeout s = interpret \Close -> embed $ IO.gracefulClose s timeout
