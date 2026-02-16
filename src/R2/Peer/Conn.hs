{-# LANGUAGE DeriveFunctor #-}

module R2.Peer.Conn
  ( HighLevel (..),
    ConnTransport (..),
    NewConnection (..),
    Connection (..),
    Node (..),
    nodeAddr,
    nodeTransport,
    nodeChan,
    Event (..),
    Peer (..),
    superviseNode,
    highLevelNodeChan,
  )
where

import Polysemy
import R2
import R2.Bus
import R2.Peer.Proto

newtype HighLevel chan = HighLevel {unHighLevel :: chan}
  deriving stock (Functor)

data NewConnection chan = NewConnection
  { newConnAddr :: Maybe Address,
    newConnTransport :: ConnTransport,
    newConnChan :: Bidirectional chan
  }

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: Bidirectional chan,
    connHighLevelChan :: HighLevel (Bidirectional chan)
  }

data Event chan where
  ConnFullyInitialized :: Connection chan -> Event chan
  ConnDestroyed :: Address -> Event chan

data Node chan
  = AcceptedNode (NewConnection chan)
  | ConnectedNode (Connection chan)

instance Eq (Node chan) where
  a == b = nodeAddr a == nodeAddr b

nodeAddr :: Node chan -> Maybe Address
nodeAddr (AcceptedNode (NewConnection {newConnAddr})) = newConnAddr
nodeAddr (ConnectedNode (Connection {connAddr})) = Just connAddr

nodeTransport :: Node chan -> ConnTransport
nodeTransport (AcceptedNode (NewConnection {newConnTransport})) = newConnTransport
nodeTransport (ConnectedNode (Connection {connTransport})) = connTransport

nodeChan :: Node chan -> Bidirectional chan
nodeChan (AcceptedNode (NewConnection {newConnChan})) = newConnChan
nodeChan (ConnectedNode (Connection {connChan})) = connChan

highLevelNodeChan :: Node chan -> Maybe (HighLevel (Bidirectional chan))
highLevelNodeChan (AcceptedNode _) = Nothing
highLevelNodeChan (ConnectedNode Connection {connHighLevelChan}) = Just connHighLevelChan

data Peer chan m a where
  SuperviseNode :: Maybe Address -> ConnTransport -> Bidirectional chan -> Peer chan m (Connection chan)

makeSem ''Peer
