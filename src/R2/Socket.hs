module R2.Socket (inputToSocket, outputToSocket, closeToSocket) where

import Control.Monad
import Network.Socket qualified as IO
import Network.Socket.ByteString qualified as IO
import Polysemy
import Polysemy.Extra.Trace
import Polysemy.Trace
import Polysemy.Transport
import Transport.Maybe

inputToSocket :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpreterFor ByteInputWithEOF r
inputToSocket bufferSize s = traceTagged ("inputToSocket " <> show s) . go . raiseUnder @Trace
  where
    go = interpret \Input -> do
      str <- embed (eofToNothing <$> IO.recv s bufferSize)
      trace $ show str
      pure str

outputToSocket :: (Member (Embed IO) r, Member Trace r) => IO.Socket -> InterpreterFor ByteOutput r
outputToSocket s = traceTagged ("outputToSocket " <> show s) . go . raiseUnder @Trace
  where
    go = interpret \(Output str) -> void $ trace (show str) >> embed (IO.send s str)

closeToSocket :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor Close r
closeToSocket s = interpret \Close -> embed $ IO.gracefulClose s 2000
