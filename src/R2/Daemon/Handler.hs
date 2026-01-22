module R2.Daemon.Handler (OverlayConnection (..), EstablishedConnection (..), listNodes, connectNode, routeTo, routedFrom, handleMsg) where

import Control.Monad
import Data.ByteString (ByteString)
import Data.Maybe
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Reader
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer
import R2.Peer.Conn
import R2.Peer.MakeNode
import R2.Peer.Proto

listNodes :: (Member (Reader [Node chan]) r, Member (Output ByteString) r) => Sem r ()
listNodes = ask >>= output . encodeStrict . ResNodeList . mapMaybe nodeAddr

connectNode ::
  ( Member (MakeNode q) r,
    Member (Bus q ByteString) r,
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
    Members ByteTransport r,
    Member (MakeNode chan) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (Bus chan ByteString) r,
    Member Fail r,
    Member Async r
  ) =>
  Connection chan ->
  ByteString ->
  Sem r ()
handleMsg Connection {..} bs =
  decodeStrictSem bs >>= \case
    ReqListNodes -> listNodes
    (ReqConnectNode transport maybeNodeID) -> connectNode connAddr transport maybeNodeID
    MsgExit -> busChan (inboundChan connChan) $ putChan Nothing
    msg -> fail $ "unexpected message: " <> show msg
