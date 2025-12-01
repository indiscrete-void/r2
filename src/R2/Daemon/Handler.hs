module R2.Daemon.Handler (StatelessConnection (..), EstablishedConnection (..), tunnelProcess, listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Control.Monad.Extra
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
import R2.Bus
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Peer
import System.Process.Extra

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

routeTo :: (Member (LookupChan EstablishedConnection (Maybe chan)) r, Member (Bus chan Message) r, Member (Output Message) r) => Address -> RouteTo Message -> Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan ToWorld (EstablishedConnection routeToAddr)
  case mChan of
    Just chan -> busChan chan $ putChan (Just $ MsgR2 $ MsgRoutedFrom routedFrom)
    Nothing -> output $ MsgR2 $ MsgRouteToErr routeToAddr "unreachable"

routeToError :: (Member (LookupChan EstablishedConnection (Maybe chan)) r, Member (Bus chan Message) r) => Address -> String -> Sem r ()
routeToError addr _ = do
  mChan <- lookupChan ToWorld (EstablishedConnection addr)
  whenJust mChan \chan -> busChan chan (putChan Nothing)

routedFrom :: (Member (LookupChan StatelessConnection chan) r, Member (Bus chan Message) r) => RoutedFrom Message -> Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  chan <- lookupChan FromWorld (StatelessConnection routedFromNode)
  busChan chan $ putChan (Just routedFromData)

handleR2Msg ::
  ( Member (LookupChan EstablishedConnection (Maybe chan)) r,
    Member (LookupChan StatelessConnection chan) r,
    Member (Bus chan Message) r,
    Member (Output Message) r
  ) =>
  Address ->
  R2Message Message ->
  Sem r ()
handleR2Msg connAddr (MsgRouteTo msg) = routeTo connAddr msg
handleR2Msg _ (MsgRouteToErr addr err) = routeToError addr err
handleR2Msg _ (MsgRoutedFrom msg) = routedFrom msg

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
  MsgR2 r2Msg -> handleR2Msg connAddr r2Msg
  MsgExit -> busChan (nodeBusChan FromWorld connChan) $ putChan Nothing
  msg -> fail $ "unexpected message: " <> show msg
