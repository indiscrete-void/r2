module R2.Daemon.Handler (listNodes, connectNode, handleMsg) where

import Control.Monad
import Data.ByteString (ByteString)
import Data.Functor
import Polysemy
import Polysemy.Async
import Polysemy.Conc.Interpreter.Events
import Polysemy.Fail
import Polysemy.Reader
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.Conn
import R2.Peer.Proto
import R2.Peer.Routing

listNodes :: (Member (Reader [Node chan]) r, Member (Output DaemonToClientMessage) r) => Sem r ()
listNodes = do
  peerList <-
    ask <&> map \node ->
      DaemonPeerInfo
        { daemonPeerAddr = nodeAddr node,
          daemonPeerTransport = nodeTransport node
        }
  output $ ResNodeList peerList

connectNode ::
  ( Member (Bus chan ByteString) r,
    Member Fail r,
    Member (EventConsumer (Event chan)) r,
    Member Async r,
    Member (Peer chan) r
  ) =>
  Connection chan ->
  Maybe Address ->
  Sem r ()
connectNode
  Connection
    { connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan,
      connAddr = router
    }
  (Just addr) = void $ makeR2ConnectedNode addr router routerOutboundChan
connectNode _ Nothing = fail "node without addr unsupported"

handleMsg ::
  ( Member (Reader [Node chan]) r,
    Members ByteTransport r,
    Member (Bus chan ByteString) r,
    Member (EventConsumer (Event chan)) r,
    Member Fail r,
    Member Async r,
    Member (Peer chan) r
  ) =>
  Connection chan ->
  ByteString ->
  Sem r ()
handleMsg conn bs =
  decodeStrictSem bs >>= \case
    ReqListNodes -> encodeOutput listNodes
    (ReqConnectNode _ maybeNodeID) -> connectNode conn maybeNodeID
    msg -> fail $ "unexpected message: " <> show msg
