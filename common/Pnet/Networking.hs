module Pnet.Networking
  ( Node (..),
    ipchainsNode,
    recvIf,
    ioNode,
  )
where

import Control.Arrow
import Data.ByteString
import Pnet
import Polysemy
import Polysemy.Input
import Polysemy.Output

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
