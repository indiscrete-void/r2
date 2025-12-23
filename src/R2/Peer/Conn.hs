module R2.Peer.Conn
  ( ConnTransport (..),
    NewConnection (..),
    Connection (..),
    Node (..),
    nodeAddr,
    nodeChan,
  )
where

import R2
import R2.Bus
import R2.Peer.Proto

data ConnTransport = R2 Address | Pipe ProcessTransport | Socket
  deriving stock (Show)

data NewConnection chan = NewConnection
  { newConnAddr :: Maybe Address,
    newConnTransport :: ConnTransport,
    newConnChan :: Bidirectional chan
  }

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: Bidirectional chan
  }

data Node chan
  = AcceptedNode (NewConnection chan)
  | ConnectedNode (Connection chan)

instance Eq (Node chan) where
  a == b = nodeAddr a == nodeAddr b

nodeAddr :: Node chan -> Maybe Address
nodeAddr (AcceptedNode (NewConnection {newConnAddr})) = newConnAddr
nodeAddr (ConnectedNode (Connection {connAddr})) = Just connAddr

nodeChan :: Node chan -> Bidirectional chan
nodeChan (AcceptedNode (NewConnection {newConnChan})) = newConnChan
nodeChan (ConnectedNode (Connection {connChan})) = connChan
