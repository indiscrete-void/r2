module R2.Daemon.Handler (tunnelProcess, listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Data.Maybe
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Reader
import Polysemy.Scoped
import Polysemy.Transport
import R2
import R2.Daemon
import R2.Daemon.Bus
import R2.Daemon.MakeNode
import R2.Peer
import System.Process.Extra

tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Async r
  ) =>
  String ->
  Sem r ()
tunnelProcess cmd = execIO (ioShell cmd) ioToMsg

listNodes :: (Member (Reader [Node chan]) r, Member (Output Message) r) => Sem r ()
listNodes = ask >>= output . ResNodeList . mapMaybe nodeAddr

connectNode ::
  ( Members (Transport Message Message) r,
    Member (MakeNode q) r,
    Member (Bus q Message) r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode router transport maybeNewNodeID = do
  chan <- makeAcceptedNode maybeNewNodeID (Pipe router transport)
  msgToIO $ nodeBusChanToIO chan

routeTo ::
  ( Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member Fail r
  ) =>
  Address ->
  RouteTo Message ->
  Sem r ()
routeTo = r2 sendTo
  where
    sendTo addr msg = do
      (Just chan) <- nodeBusGetChan addr
      busChan (nodeBusChan ToWorld chan) $ putChan $ Just $ MsgRoutedFrom msg

routedFrom ::
  ( Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  RoutedFrom Message ->
  Sem r ()
routedFrom addr (RoutedFrom routedFromNode routedFromData) = do
  chan <-
    nodeBusGetChan routedFromNode >>= \case
      Just chan -> pure chan
      Nothing -> makeConnectedNode routedFromNode (R2 addr)
  busChan (nodeBusChan FromWorld chan) $ putChan (Just routedFromData)

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (MakeNode chan) r,
    Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r
  ) =>
  String ->
  Connection q ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> listNodes
  (ReqConnectNode transport maybeNodeID) -> connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> tunnelProcess cmd
  MsgRouteTo msg -> routeTo connAddr msg
  MsgRoutedFrom msg -> routedFrom connAddr msg
  msg -> fail $ "unexpected message: " <> show msg
