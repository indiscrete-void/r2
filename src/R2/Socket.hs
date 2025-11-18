module R2.Socket (inputToSocket, outputToSocket, closeToSocket, runSocketIO) where

import Control.Exception
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
    tryRecv = exceptionToNothing @IOException ("recv" <> show s) (IO.recv s bufferSize)
    go = interpret \Input -> do
      str <- embed ((eofToNothing =<<) <$> tryRecv)
      trace $ show str
      pure str

outputToSocket :: (Member (Embed IO) r, Member Trace r) => IO.Socket -> InterpreterFor ByteOutput r
outputToSocket s = traceTagged ("outputToSocket " <> show s) . go . raiseUnder @Trace
  where
    trySend str = exceptionToUnit @IOException ("send " <> show s) $ void (IO.send s str)
    go = interpret \(Output str) -> void $ trace (show str) >> embed (trySend str)

closeToSocket :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor Close r
closeToSocket s = interpret \Close -> embed tryClose
  where
    tryClose = exceptionToUnit @IOException ("close " <> show s) $ IO.gracefulClose s 2000

runSocketIO :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpretersFor '[ByteInputWithEOF, ByteOutput, Close] r
runSocketIO bufferSize s = closeToSocket s . outputToSocket s . inputToSocket bufferSize s
