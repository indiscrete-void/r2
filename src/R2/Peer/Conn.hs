{-# LANGUAGE DeriveFunctor #-}

module R2.Peer.Conn
  ( HighLevel (..),
    ConnTransport (..),
    NewConnection (..),
    Connection (..),
    Node (..),
    nodeAddrSet,
    nodeTransport,
    nodeChan,
    Event (..),
    Peer (..),
    superviseNode,
    highLevelNodeChan,
    nodeConn,
  )
where

import Polysemy
import R2
import R2.Bus
import R2.Peer.Proto

newtype HighLevel chan = HighLevel {unHighLevel :: chan}
  deriving stock (Functor)

data NewConnection chan = NewConnection
  { newConnAddrSet :: NetworkAddrSet,
    newConnTransport :: ConnTransport,
    newConnChan :: Bidirectional chan
  }

data Connection chan = Connection
  { connAddrSet :: NetworkAddrSet,
    connTransport :: ConnTransport,
    connChan :: Bidirectional chan,
    connHighLevelChan :: HighLevel (Bidirectional chan)
  }

data Event chan where
  ConnFullyInitialized :: Connection chan -> Event chan
  ConnDestroyed :: NetworkAddrSet -> Event chan

data Node chan
  = AcceptedNode (NewConnection chan)
  | ConnectedNode (Connection chan)

instance Eq (Node chan) where
  a == b =
    let (NetworkAddrSet aAddrs) = nodeAddrSet a
        (NetworkAddrSet bAddrs) = nodeAddrSet b
     in aAddrs == bAddrs

nodeAddrSet :: Node chan -> NetworkAddrSet
nodeAddrSet (AcceptedNode (NewConnection {newConnAddrSet})) = newConnAddrSet
nodeAddrSet (ConnectedNode (Connection {connAddrSet})) = connAddrSet

nodeTransport :: Node chan -> ConnTransport
nodeTransport (AcceptedNode (NewConnection {newConnTransport})) = newConnTransport
nodeTransport (ConnectedNode (Connection {connTransport})) = connTransport

nodeChan :: Node chan -> Bidirectional chan
nodeChan (AcceptedNode (NewConnection {newConnChan})) = newConnChan
nodeChan (ConnectedNode (Connection {connChan})) = connChan

nodeConn :: Node chan -> Maybe (Connection chan)
nodeConn (AcceptedNode _) = Nothing
nodeConn (ConnectedNode conn) = Just conn

highLevelNodeChan :: Node chan -> Maybe (HighLevel (Bidirectional chan))
highLevelNodeChan (AcceptedNode _) = Nothing
highLevelNodeChan (ConnectedNode Connection {connHighLevelChan}) = Just connHighLevelChan

data Peer chan m a where
  SuperviseNode :: NetworkAddrSet -> ConnTransport -> Bidirectional chan -> Peer chan m (Connection chan)

makeSem ''Peer
