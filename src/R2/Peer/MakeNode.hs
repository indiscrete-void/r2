module R2.Peer.MakeNode
  ( MakeNode (..),
    makeNode,
    makeAcceptedNode,
    makeConnectedNode,
    runMakeNode,
    makeR2ConnectedNode,
  )
where

import Control.Monad.Loops
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.Conn
import R2.Peer.Proto

data MakeNode chan m a where
  MakeNode :: Node chan -> MakeNode chan m ()

makeSem ''MakeNode

makeAcceptedNode ::
  ( Member (Bus chan d) r,
    Member (MakeNode chan) r
  ) =>
  Maybe Address ->
  ConnTransport ->
  Sem r (Bidirectional chan)
makeAcceptedNode addr transport = do
  chan <- makeBidirectionalChan
  makeNode $ AcceptedNode (NewConnection addr transport chan)
  pure chan

makeConnectedNode ::
  ( Member (Bus chan d) r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  ConnTransport ->
  Sem r (Bidirectional chan)
makeConnectedNode addr transport = do
  chan <- makeBidirectionalChan
  makeNode $ ConnectedNode (Connection addr transport chan)
  pure chan

outboundChanToR2 :: (Member (Bus chan Message) r) => Outbound chan -> Outbound chan -> Address -> Sem r ()
outboundChanToR2 (Outbound routerChan) (Outbound chan) addr = do
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgR2 . MsgRouteTo . RouteTo addr . encodeBase64)

makeR2ConnectedNode ::
  ( Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member Async r
  ) =>
  Address ->
  Address ->
  Outbound chan ->
  Sem r (Bidirectional chan)
makeR2ConnectedNode addr router routerOutboundChan = do
  chan@Bidirectional {outboundChan = Outbound -> clientOutboundChan} <- makeConnectedNode addr (R2 router)
  async_ $ outboundChanToR2 routerOutboundChan clientOutboundChan addr
  pure chan

runMakeNode :: (Node chan -> Sem r ()) -> Sem (MakeNode chan ': r) a -> Sem r a
runMakeNode f = interpret \case MakeNode newConn -> f newConn
