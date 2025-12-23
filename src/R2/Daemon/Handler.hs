module R2.Daemon.Handler (StatelessConnection (..), EstablishedConnection (..), tunnelProcess, listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Control.Monad
import Data.Maybe
import Debug.Trace
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Reader
import Polysemy.Scoped
import Polysemy.Serialize
import Polysemy.Transport
import R2
import R2.Bus
import R2.Peer
import R2.Peer.Conn
import R2.Peer.MakeNode
import R2.Peer.Proto
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
  ( Member (MakeNode q) r,
    Member (Bus q Message) r,
    Member Fail r,
    Member Async r,
    Member (LookupChan EstablishedConnection (Bidirectional q)) r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode router _ (Just addr) = do
  Just (Bidirectional {outboundChan = Outbound -> routerOutboundChan}) <- lookupChan (EstablishedConnection router)
  void $ makeR2ConnectedNode addr router routerOutboundChan
connectNode _ _ Nothing = fail "node without addr unsupported"

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (MakeNode chan) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r
  ) =>
  String ->
  Connection chan ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> listNodes
  (ReqConnectNode transport maybeNodeID) -> connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> tunnelProcess cmd
  MsgR2 r2Msg -> handleR2Msg connAddr r2Msg
  MsgExit -> busChan (inboundChan connChan) $ putChan Nothing
  msg -> fail $ "unexpected message: " <> show msg
