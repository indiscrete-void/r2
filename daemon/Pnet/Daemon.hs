module Pnet.Daemon (IpchainsMessage (..), NodeToNodeMessage (..)) where

import Data.ByteString (ByteString)
import Data.Serialize
import GHC.Generics
import Pnet

data IpchainsMessage = IpchainsMessage
  { ipchainsMessageSrc :: NodeID,
    ipchainsMessageDst :: NodeID,
    ipchainsMessageData :: ByteString
  }
  deriving stock (Show, Generic)

data NodeToNodeMessage where
  Ipchains :: IpchainsMessage -> NodeToNodeMessage
  deriving stock (Show, Generic)

instance Serialize IpchainsMessage

instance Serialize NodeToNodeMessage
