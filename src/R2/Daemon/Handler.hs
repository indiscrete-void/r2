module R2.Daemon.Handler (StatelessConnection (..), EstablishedConnection (..), tunnelProcess, listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Data.Maybe
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Reader
import Polysemy.Scoped
import Polysemy.Serialize
import Polysemy.Transport
import R2
import R2.Daemon.Bus
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Peer
import System.Process.Extra
import Text.Printf

newtype StatelessConnection = StatelessConnection Address

newtype EstablishedConnection = EstablishedConnection Address

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
  msgToIO $ runSerialization $ nodeBusChanToIO chan

routeTo :: (Member (LookupChan EstablishedConnection (Maybe chan)) r, Member (Bus chan Message) r, Member Fail r) => Address -> RouteTo Message -> Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan ToWorld (EstablishedConnection routeToAddr)
  case mChan of
    Just chan -> busChan chan $ putChan (Just $ MsgRoutedFrom routedFrom)
    Nothing -> fail $ printf "no node %s present" (show routeToAddr)

routedFrom :: (Member (LookupChan StatelessConnection chan) r, Member (Bus chan Message) r) => RoutedFrom Message -> Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  chan <- lookupChan FromWorld (StatelessConnection routedFromNode)
  busChan chan $ putChan (Just routedFromData)

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (MakeNode chan) r,
    Member (LookupChan EstablishedConnection (Maybe chan)) r,
    Member (LookupChan StatelessConnection chan) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r
  ) =>
  String ->
  Connection chan ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> do
    listNodes
  (ReqConnectNode transport maybeNodeID) -> do
    connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> do
    tunnelProcess cmd
  MsgRouteTo msg -> routeTo connAddr msg
  MsgRoutedFrom msg -> routedFrom msg
  MsgExit -> busChan (nodeBusChan FromWorld connChan) $ putChan Nothing
  msg -> fail $ "unexpected message: " <> show msg
