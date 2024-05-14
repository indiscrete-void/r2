module Pnet.Networking
  ( Node (..),
    IpchainsMessage (..),
    NodeToNodeMessage (..),
    ipchainsNode,
    recvIf,
    ioNode,
    sockNode,
    nodeToIO,
    unserializeNode,
  )
where

import Control.Arrow
import Data.ByteString
import Data.Serialize
import GHC.Generics
import Pnet
import Polysemy hiding (send)
import Polysemy.Fail
import Polysemy.Input
import Polysemy.Output
import Polysemy.Serialize
import Polysemy.Socket

data IpchainsMessage = IpchainsMessage
  { ipchainsMessageSrc :: NodeID,
    ipchainsMessageDst :: NodeID,
    ipchainsMessageData :: ByteString
  }
  deriving stock (Show, Generic)

data NodeToNodeMessage where
  Ipchains :: IpchainsMessage -> NodeToNodeMessage
  Ping :: NodeToNodeMessage
  Pong :: NodeToNodeMessage
  deriving stock (Show, Generic)

data Node m i o = Node
  { nodeSend :: o -> m (),
    nodeRecv :: m i
  }

recvIf :: (Monad m) => m i -> (i -> Bool) -> m i
recvIf recv f = do
  i <- recv
  if f i
    then pure i
    else recvIf recv f

unserializeNode :: (Member Fail r, Member Decoder r) => Node (Sem r) ByteString ByteString -> Node (Sem r) NodeToNodeMessage NodeToNodeMessage
unserializeNode (Node routerSend routerRecv) =
  Node
    { nodeSend = routerSend . serialize,
      nodeRecv = deserializeFrom routerRecv
    }

ipchainsNode :: (Monad m) => NodeID -> Node m IpchainsMessage IpchainsMessage -> NodeID -> Node m ByteString ByteString
ipchainsNode selfID (Node routerSend routerRecv) nodeID =
  Node
    { nodeSend = routerSend . IpchainsMessage selfID nodeID,
      nodeRecv =
        ipchainsMessageData
          <$> recvIf
            routerRecv
            ( uncurry (&&)
                . ( (selfID ==) . ipchainsMessageDst
                      &&& (nodeID ==) . ipchainsMessageSrc
                  )
            )
    }

ioNode :: (Member (Input i) r, Member (Output o) r) => Node (Sem r) i o
ioNode =
  Node
    { nodeSend = output,
      nodeRecv = input
    }

sockNode :: (Member (Socket i o s) r) => s -> Node (Sem r) (Maybe i) o
sockNode s =
  Node
    { nodeSend = oToSock s . output,
      nodeRecv = ioToSock s input
    }

nodeToIO :: forall i o r. Node (Sem r) i o -> InterpretersFor (Input i ': Output o ': '[]) r
nodeToIO (Node send recv) = nodeToO . nodeToI
  where
    nodeToI = interpret \case Input -> raise @(Output o) recv
    nodeToO = interpret \case Output str -> send str

instance Serialize IpchainsMessage

instance Serialize NodeToNodeMessage
