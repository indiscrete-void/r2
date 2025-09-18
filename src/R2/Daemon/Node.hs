module R2.Daemon.Node
  ( ConnTransport (..),
    NewConnection (..),
    Connection (..),
    Node (..),
    nodeAddr,
    nodeChan,
  )
where

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
  deriving stock (Show)

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: NodeBusChan chan
  }
  deriving stock (Show)

data Node chan
  = AcceptedNode (NewConnection chan)
  | ConnectedNode (Connection chan)
  deriving stock (Show)

instance Eq (Node chan) where
  a == b = nodeAddr a == nodeAddr b

nodeAddr :: Node chan -> Maybe Address
nodeAddr (AcceptedNode (NewConnection {newConnAddr})) = newConnAddr
nodeAddr (ConnectedNode (Connection {connAddr})) = Just connAddr

nodeChan :: Node chan -> NodeBusChan chan
nodeChan (AcceptedNode (NewConnection {newConnChan})) = newConnChan
nodeChan (ConnectedNode (Connection {connChan})) = connChan
