module R2.Daemon.MakeNode
  ( MakeNode (..),
    makeNode,
    makeAcceptedNode,
    makeConnectedNode,
    runMakeNode,
  )
where

import Polysemy
import R2
import R2.Bus
import R2.Daemon.Node

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

runMakeNode :: (Node chan -> Sem r ()) -> Sem (MakeNode chan ': r) a -> Sem r a
runMakeNode f = interpret \case MakeNode newConn -> f newConn
