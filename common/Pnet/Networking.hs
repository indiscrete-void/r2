module Pnet.Networking
  ( Node (..),
    ipchainsNode,
    recvIf,
  )
where

import Data.ByteString
import Pnet

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

ipchainsNode :: (Monad m) => NodeID -> Node m IpchainsMessage IpchainsMessage -> Node m ByteString ByteString
ipchainsNode nodeID (Node {nodeSend = routerSend, nodeRecv = routerRecv}) =
  Node
    { nodeSend = routerSend . IpchainsMessage nodeID,
      nodeRecv = ipchainsMessageData <$> recvIf routerRecv ((nodeID ==) . ipchainsMessageNodeID)
    }
