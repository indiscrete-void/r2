module R2.Daemon.Handler (tunnelProcess, listNodes, connectNode, handleMsg) where

import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Daemon
import R2.Daemon.Bus
import R2.Daemon.Storage
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Trace r,
    Member Async r
  ) =>
  String ->
  Sem r ()
tunnelProcess cmd = traceTagged "tunnel" $ execIO (ioShell cmd) ioToMsg

listNodes :: (Member (Storage chan) r, Member (Output Message) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map connAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (ResNodeList nodeList)

connectNode ::
  ( Members (Transport Message Message) r,
    Member (NodeBus NewConnection q Message) r,
    Member (Bus q Message) r,
    Member Trace r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode router transport maybeNewNodeID =
  msgToIO $ nodeBusToIO (NewConnection maybeNewNodeID (Pipe router transport))

handleRouteTo :: (Member (NodeBus Address chan Message) r, Member (Bus chan Message) r) => Address -> RouteTo Message -> Sem r ()
handleRouteTo = r2 (\reqAddr -> useNodeBusChan ToWorld reqAddr . putChan . Just . MsgRoutedFrom)

handleRoutedFrom :: (Member (NodeBus Address chan Message) r, Member (Bus chan Message) r) => RoutedFrom Message -> Sem r ()
handleRoutedFrom (RoutedFrom routedFromNode routedFromData) = useNodeBusChan FromWorld routedFromNode $ putChan (Just routedFromData)

handleMsg ::
  ( Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r,
    Member Trace r
  ) =>
  String ->
  Connection q ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> listNodes
  (ReqConnectNode transport maybeNodeID) -> connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> tunnelProcess cmd
  MsgRouteTo routeTo -> handleRouteTo connAddr routeTo
  MsgRoutedFrom routedFrom -> handleRoutedFrom routedFrom
  msg -> fail $ "unexpected message: " <> show msg
