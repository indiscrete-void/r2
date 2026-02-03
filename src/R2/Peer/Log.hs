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
  LogRecv :: Maybe Address -> ByteString -> Log
  LogSend :: Maybe Address -> ByteString -> Log
  LogDisconnected :: Maybe Address -> Log
  LogError :: Maybe Address -> String -> Log

logShowOptionalAddr :: Maybe Address -> String
logShowOptionalAddr (Just addr) = show addr
logShowOptionalAddr Nothing = "unknown node"

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv mAddr msg) = traceTagged (printf "<-%s" $ logShowOptionalAddr mAddr) $ when (verbosity > 0) $ trace (BC.unpack msg)
    go (LogSend mAddr msg) = traceTagged (printf "->%s" $ logShowOptionalAddr mAddr) $ when (verbosity > 1) $ trace (BC.unpack msg)
    go (LogDisconnected mAddr) = trace $ printf "%s disconnected" $ logShowOptionalAddr mAddr
    go (LogError mAddr err) = trace $ printf "%s error: %s" (logShowOptionalAddr mAddr) err

ioToLog :: (Member (Output Log) r) => Maybe Address -> Sem (Append ByteTransport r) a -> Sem (Append ByteTransport r) a
ioToLog mAddr =
  intercept @(Output ByteString) (\(Output o) -> output (LogSend mAddr o) >> output o)
    . intercept @(InputWithEOF ByteString) (\Input -> input >>= \i -> whenJust i (output . LogRecv mAddr) >> pure i)

ioToNodeChanLogged :: (Member (Bus chan ByteString) r, Member (Output Log) r) => Maybe Address -> Bidirectional chan -> InterpretersFor ByteTransport r
ioToNodeChanLogged mAddr chan = ioToChan chan . ioToLog mAddr
