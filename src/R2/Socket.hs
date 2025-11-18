module R2.Socket (inputToSocket, outputToSocket, closeToSocket, runSocketIO) where

import Control.Exception
import Control.Monad
import Data.ByteString
import Network.Socket qualified as IO
import Network.Socket.ByteString qualified as IO
import Polysemy
import Polysemy.Extra.Trace
import Polysemy.Trace
import Polysemy.Transport
import System.IO
import Text.Printf
import Transport.Maybe

tryRecv :: IO.Socket -> Int -> IO (Maybe ByteString)
tryRecv s bufferSize = (eofToNothing <$> IO.recv s bufferSize) `catch` \(e :: IOException) -> Nothing <$ hPutStrLn stderr (printf "recv %s error: %s" (show s) (show e))

trySend :: IO.Socket -> ByteString -> IO ()
trySend s b = void (IO.send s b) `catch` \(e :: IOException) -> hPutStrLn stderr (printf "send %s error: %s" (show s) (show e))

tryClose :: IO.Socket -> Int -> IO ()
tryClose s timeout = IO.gracefulClose s timeout `catch` \(e :: IOException) -> hPutStrLn stderr (printf "close %s error: %s" (show s) (show e))

inputToSocket :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpreterFor ByteInputWithEOF r
inputToSocket bufferSize s = traceTagged ("inputToSocket " <> show s) . go . raiseUnder @Trace
  where
    go = interpret \Input -> do
      str <- embed (tryRecv s bufferSize)
      trace $ show str
      pure str

outputToSocket :: (Member (Embed IO) r, Member Trace r) => IO.Socket -> InterpreterFor ByteOutput r
outputToSocket s = traceTagged ("outputToSocket " <> show s) . go . raiseUnder @Trace
  where
    go = interpret \(Output str) -> void $ trace (show str) >> embed (trySend s str)

closeToSocket :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor Close r
closeToSocket s = interpret \Close -> embed $ tryClose s 2000

runSocketIO :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpretersFor '[ByteInputWithEOF, ByteOutput, Close] r
runSocketIO bufferSize s = closeToSocket s . outputToSocket s . inputToSocket bufferSize s
