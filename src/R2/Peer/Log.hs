module R2.Peer.Log (Log (..), logToTrace, ioToLog, ioToNodeBusChanLogged) where

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
import R2.Peer.Proto
import Text.Printf (printf)

data Log where
  LogConnected :: Node chan -> Log
  LogRecv :: Node chan -> ByteString -> Log
  LogSend :: Node chan -> ByteString -> Log
  LogDisconnected :: Node chan -> Log
  LogError :: Node chan -> String -> Log

logShowOptionalAddr :: Maybe Address -> String
logShowOptionalAddr (Just addr) = show addr
logShowOptionalAddr Nothing = "unknown node"

logShowNode :: Node chan -> String
logShowNode node = logShowOptionalAddr (nodeAddr node)

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv node msg) = traceTagged (printf "<-%s" $ logShowNode node) $ when (verbosity > 0) $ trace (BC.unpack msg)
    go (LogSend node msg) = traceTagged (printf "->%s" (logShowNode node)) $ when (verbosity > 1) $ trace (BC.unpack msg)
    go (LogDisconnected node) = trace $ printf "%s disconnected" (logShowNode node)
    go (LogError node err) = trace $ printf "%s error: %s" (logShowNode node) err

ioToLog :: (Member (Output Log) r) => Node chan -> Sem (Append (Transport ByteString ByteString) r) a -> Sem (Append (Transport ByteString ByteString) r) a
ioToLog node =
  intercept @(Output ByteString) (\(Output o) -> output (LogSend node o) >> output o)
    . intercept @(InputWithEOF ByteString) (\Input -> input >>= \i -> whenJust i (output . LogRecv node) >> pure i)

ioToNodeBusChanLogged :: (Member (Bus chan ByteString) r, Member (Output Log) r) => Node chan -> InterpretersFor (Transport ByteString ByteString) r
ioToNodeBusChanLogged node = ioToChan (nodeChan node) . ioToLog node
