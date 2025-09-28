module R2.Daemon.Handler (OverlayAddress (..), tunnelProcess, listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Data.Maybe
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Reader
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Daemon.Bus
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

newtype OverlayAddress = OverlayAddress Address

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

routeTo :: (Member (LookupChan Address chan) r, Member (Bus chan Message) r, Member Fail r) => Address -> RouteTo Message -> Sem r ()
routeTo = r2 (\reqAddr -> useNodeBusChan ToWorld reqAddr . putChan . Just . MsgRoutedFrom)

routedFrom :: (Member (LookupChan OverlayAddress chan) r, Member (Bus chan Message) r, Member Fail r) => RoutedFrom Message -> Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = useNodeBusChan FromWorld (OverlayAddress routedFromNode) $ putChan (Just routedFromData)

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (MakeNode chan) r,
    Member (LookupChan OverlayAddress chan) r,
    Member (LookupChan Address chan) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r,
    Member Trace r
  ) =>
  String ->
  Connection chan ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> do
    trace "listing connected nodes"
    listNodes
  (ReqConnectNode transport maybeNodeID) -> do
    case maybeNodeID of
      Just addr -> trace $ Text.printf "connecting %s over %s" (show addr) (show transport)
      Nothing -> trace $ Text.printf "connecting unknown node over %s" (show transport)
    connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> do
    trace (Text.printf "tunneling `%s`" cmd)
    tunnelProcess cmd
  MsgRouteTo msg@(RouteTo {..}) -> do
    trace $ Text.printf "routing `%s` to %s" (show routeToData) (show routeToNode)
    routeTo connAddr msg
  MsgRoutedFrom msg@(RoutedFrom {..}) -> do
    trace $ Text.printf "`%s` routed from %s" (show routedFromData) (show routedFromNode)
    routedFrom msg
  MsgExit -> do
    trace $ Text.printf "closing input queue"
    busChan (nodeBusChan FromWorld connChan) $ putChan Nothing
  msg -> fail $ "unexpected message: " <> show msg
