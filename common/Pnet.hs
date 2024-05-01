{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDeriving #-}

module Pnet
  ( NodeID,
    NodeToNodeMessage (..),
    NodeToManagerMessage (..),
    ManagerToNodeMessage (..),
    pnetSocketAddr,
    pnetSocket,
    withPnetSocket,
    bufferSize,
  )
where

import Control.Exception
import Data.Maybe
import Data.Serialize
import GHC.Generics
import Network.Socket
import System.Environment

type NodeID = String

data NodeToNodeMessage deriving stock (Show, Generic)

data NodeToManagerMessage where
  NodeList :: [NodeID] -> NodeToManagerMessage
  deriving stock (Show, Generic)

data ManagerToNodeMessage where
  ListNodes :: ManagerToNodeMessage
  Other :: NodeToNodeMessage -> ManagerToNodeMessage
  deriving stock (Show, Generic)

bufferSize :: Int
bufferSize = 8192

defaultPnetSocketPath :: FilePath
defaultPnetSocketPath = "/run/pnet.sock"

pnetSocket :: IO Socket
pnetSocket = socket AF_UNIX Stream defaultProtocol

pnetSocketAddr :: IO SockAddr
pnetSocketAddr = SockAddrUnix . fromMaybe defaultPnetSocketPath <$> lookupEnv "PNET_SOCKET_PATH"

withPnetSocket :: (Socket -> IO a) -> IO a
withPnetSocket = bracket pnetSocket close

instance Serialize NodeToNodeMessage

instance Serialize NodeToManagerMessage

instance Serialize ManagerToNodeMessage
