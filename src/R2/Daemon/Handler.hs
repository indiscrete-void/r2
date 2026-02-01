module R2.Daemon.Handler (OverlayConnection (..), EstablishedConnection (..), listNodes, connectNode, handleMsg) where

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
import R2.Peer.Conn
import R2.Peer.MakeNode
import R2.Peer.Proto

listNodes :: (Member (Reader [Node chan]) r, Member (Output DaemonToClientMessage) r) => Sem r ()
listNodes = ask >>= output . ResNodeList . mapMaybe nodeAddr

connectNode ::
  ( Member (MakeNode chan) r,
    Member (Bus chan ByteString) r,
    Member Fail r,
    Member Async r
  ) =>
  Connection chan ->
  Maybe Address ->
  Sem r ()
connectNode
  Connection
    { connChan = Bidirectional {outboundChan = Outbound -> routerOutboundChan},
      connAddr = router
    }
  (Just addr) = void $ makeR2ConnectedNode addr router routerOutboundChan
connectNode _ Nothing = fail "node without addr unsupported"

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Members ByteTransport r,
    Member (MakeNode chan) r,
    Member (Bus chan ByteString) r,
    Member Fail r,
    Member Async r
  ) =>
  Connection chan ->
  ByteString ->
  Sem r ()
handleMsg conn bs =
  decodeStrictSem bs >>= \case
    ReqListNodes -> encodeOutput listNodes
    (ReqConnectNode _ maybeNodeID) -> connectNode conn maybeNodeID
    msg -> fail $ "unexpected message: " <> show msg
