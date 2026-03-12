module R2.Peer.Log (Log (..), logToTrace, ioToLog, ioToNodeChanLogged) where

import Control.Monad
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Polysemy
import Polysemy.Extra.Trace
import Polysemy.Internal.Kind
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Options
import R2.Peer.Conn
import Text.Printf (printf)

data Log where
  LogConnected :: Node chan -> Log
  LogRecv :: Maybe NetworkAddr -> Maybe ByteString -> Log
  LogSend :: Maybe NetworkAddr -> Maybe ByteString -> Log
  LogDisconnected :: Maybe NetworkAddr -> Log
  LogError :: Maybe NetworkAddr -> String -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (show newConnAddr) (show newConnTransport)
    go (LogRecv addr msg) = traceTagged (printf "<-%s" $ show addr) $ when (verbosity > 0) $ trace (show msg)
    go (LogSend addr msg) = traceTagged (printf "->%s" $ show addr) $ when (verbosity > 1) $ trace (show msg)
    go (LogDisconnected addr) = trace $ printf "%s disconnected" $ show addr
    go (LogError addr err) = trace $ printf "%s error: %s" (show addr) err

logOut :: (Member (OutputWithEOF ByteString) r, Member (Output Log) r) => Maybe NetworkAddr -> Sem r a -> Sem r a
logOut mAddr =
  intercept @(OutputWithEOF ByteString)
    ( \(Output o) ->
        output (LogSend mAddr o) >> output o
    )

logIn :: (Member (InputWithEOF ByteString) r, Member (Output Log) r) => Maybe NetworkAddr -> Sem r a -> Sem r a
logIn mAddr =
  intercept @(InputWithEOF ByteString)
    ( \Input ->
        input >>= \i -> output (LogRecv mAddr i) >> pure i
    )

ioToLog :: (Member (Output Log) r) => Maybe NetworkAddr -> Sem (Append ByteTransport r) a -> Sem (Append ByteTransport r) a
ioToLog mAddr = logOut mAddr . logIn mAddr

ioToNodeChanLogged :: (Member (Bus chan ByteString) r, Member (Output Log) r) => Maybe NetworkAddr -> Bidirectional chan -> InterpretersFor ByteTransport r
ioToNodeChanLogged mAddr chan = ioToChan chan . ioToLog mAddr
