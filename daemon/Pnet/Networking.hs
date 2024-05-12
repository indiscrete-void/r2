module Pnet.Networking
  ( Node (..),
    ipchainsNode,
    recvIf,
    ioNode,
    sockNode,
  )
where

import Control.Arrow
import Data.ByteString
import Pnet
import Pnet.Daemon
import Polysemy
import Polysemy.Input
import Polysemy.Output
import Polysemy.Socket

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

ipchainsNode :: (Monad m) => NodeID -> Node m IpchainsMessage IpchainsMessage -> NodeID -> Node m ByteString ByteString
ipchainsNode selfID (Node {nodeSend = routerSend, nodeRecv = routerRecv}) nodeID =
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
