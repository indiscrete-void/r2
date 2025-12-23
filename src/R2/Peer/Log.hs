module R2.Peer.Log (Log (..), logToTrace, ioToLog, ioToNodeBusChanLogged) where

import Control.Monad
import Control.Monad.Extra
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
  LogRecv :: Node chan -> Message -> Log
  LogSend :: Node chan -> Message -> Log
  LogDisconnected :: Node chan -> Log
  LogError :: Node chan -> String -> Log

logShowOptionalAddr :: Maybe Address -> String
logShowOptionalAddr (Just addr) = show addr
logShowOptionalAddr Nothing = "unknown node"

logShowNode :: Node chan -> String
logShowNode node = logShowOptionalAddr (nodeAddr node)

logToTrace :: (Member Trace r) => Verbosity -> String -> InterpreterFor (Output Log) r
logToTrace verbosity cmd = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv node msg) = traceTagged (printf "<-%s" $ logShowNode node) $ case msg of
      ReqListNodes -> trace $ printf "listing connected nodes"
      ReqConnectNode transport maybeNodeID -> trace $ printf "connecting %s over %s" (logShowOptionalAddr maybeNodeID) (show transport)
      ReqTunnelProcess -> trace (printf "tunneling `%s`" cmd)
      MsgR2 (MsgRouteTo RouteTo {..}) -> when (verbosity > 1) $ trace $ printf "routing `%s` to %s" (show routeToData) (show routeToNode)
      MsgR2 (MsgRouteToErr RouteToErr {..}) -> trace $ printf "->%s: error: %s" (show routeToErrNode) routeToErrMessage
      MsgR2 (MsgRoutedFrom RoutedFrom {..}) -> when (verbosity > 1) $ trace $ printf "`%s` routed from %s" (show routedFromData) (show routedFromNode)
      msg -> when (verbosity > 0) $ trace $ printf "trace: unknown msg %s" (show msg)
    go (LogSend node msg) = traceTagged (printf "->%s" (logShowNode node)) $ case msg of
      msg@(ResNodeList _) -> trace (show msg)
      msg -> when (verbosity > 1) $ trace (show msg)
    go (LogDisconnected node) = trace $ printf "%s disconnected" (logShowNode node)
    go (LogError node err) = trace $ printf "%s error: %s" (logShowNode node) err

ioToLog :: (Member (Output Log) r) => Node chan -> Sem (Append (Transport Message Message) r) a -> Sem (Append (Transport Message Message) r) a
ioToLog node =
  intercept @(Output Message) (\(Output o) -> output (LogSend node o) >> output o)
    . intercept @(InputWithEOF Message) (\Input -> input >>= \i -> whenJust i (output . LogRecv node) >> pure i)

ioToNodeBusChanLogged :: (Member (Bus chan Message) r, Member (Output Log) r) => Node chan -> InterpretersFor (Transport Message Message) r
ioToNodeBusChanLogged node = ioToChan (nodeChan node) . ioToLog node
