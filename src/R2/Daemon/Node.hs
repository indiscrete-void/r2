module R2.Daemon.Node
  ( ConnTransport (..),
    NewConnection (..),
    Connection (..),
    Node (..),
    nodeAddr,
    nodeChan,
    MakeNode (..),
    makeNode,
    makeAcceptedNode,
    makeConnectedNode,
    runMakeNode,
    CleanNode (..),
    cleanNode,
    runCleanNode,
  )
where

import Polysemy
import R2
import R2.Daemon.Bus
import R2.Peer

data ConnTransport = R2 Address | Pipe Address ProcessTransport | Socket
  deriving stock (Show)

data NewConnection chan = NewConnection
  { newConnAddr :: Maybe Address,
    newConnTransport :: ConnTransport,
    newConnChan :: NodeBusChan chan
  }

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: NodeBusChan chan
  }

data Node chan
  = AcceptedNode (NewConnection chan)
  | ConnectedNode (Connection chan)

instance Eq (Node chan) where
  a == b = nodeAddr a == nodeAddr b

nodeAddr :: Node chan -> Maybe Address
nodeAddr (AcceptedNode (NewConnection {newConnAddr})) = newConnAddr
nodeAddr (ConnectedNode (Connection {connAddr})) = Just connAddr

nodeChan :: Node chan -> NodeBusChan chan
nodeChan (AcceptedNode (NewConnection {newConnChan})) = newConnChan
nodeChan (ConnectedNode (Connection {connChan})) = connChan

instance Show (Node chan) where
  show node = show $ nodeAddr node

data MakeNode chan m a where
  MakeNode :: Node chan -> MakeNode chan m ()

makeSem ''MakeNode

makeAcceptedNode ::
  ( Member (Bus chan d) r,
    Member (MakeNode chan) r
  ) =>
  Maybe Address ->
  ConnTransport ->
  Sem r (NodeBusChan chan)
makeAcceptedNode addr transport = do
  chan <- nodeBusMakeChan
  makeNode $ AcceptedNode (NewConnection addr transport chan)
  pure chan

makeConnectedNode ::
  ( Member (Bus chan d) r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  ConnTransport ->
  Sem r (NodeBusChan chan)
makeConnectedNode addr transport = do
  chan <- nodeBusMakeChan
  makeNode $ ConnectedNode (Connection addr transport chan)
  pure chan

runMakeNode :: (Node chan -> Sem r ()) -> Sem (MakeNode chan ': r) a -> Sem r a
runMakeNode f = interpret \case MakeNode newConn -> f newConn

data CleanNode chan m a where
  CleanNode :: Node chan -> CleanNode chan m ()

makeSem ''CleanNode

runCleanNode :: (Node chan -> Sem r ()) -> Sem (CleanNode chan ': r) a -> Sem r a
runCleanNode f = interpret \case CleanNode node -> f node
