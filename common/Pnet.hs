module Pnet
  ( NodeID,
    TunnelMessage (..),
    NodeToManagerMessage (..),
    ManagerToNodeMessage (..),
    pnetSocketAddr,
    pnetSocket,
    withPnetSocket,
    bufferSize,
    Transport (..),
  )
where

import Control.Exception
import Data.ByteString (ByteString)
import Data.Functor
import Data.Maybe
import Data.Serialize
import Debug.Trace
import GHC.Generics
import Network.Socket
import System.Environment
import System.Posix

type NodeID = String

data Transport
  = Stdio
  | Process String
  deriving stock (Show, Generic)

newtype TunnelMessage = TunnelMessage
  { tunnelMessageData :: Maybe ByteString
  }
  deriving stock (Show, Generic)

data NodeToManagerMessage where
  DaemonNodeData :: TunnelMessage -> NodeToManagerMessage
  NodeList :: [NodeID] -> NodeToManagerMessage
  deriving stock (Show, Generic)

data ManagerToNodeMessage where
  NodeAvailability :: Transport -> Maybe NodeID -> ManagerToNodeMessage
  ManagerNodeData :: TunnelMessage -> ManagerToNodeMessage
  ListNodes :: ManagerToNodeMessage
  deriving stock (Show, Generic)

bufferSize :: Int
bufferSize = 8192

defaultPnetSocketPath :: FilePath
defaultPnetSocketPath = "/run/pnet.sock"

defaultUserPnetSocketPath :: IO FilePath
defaultUserPnetSocketPath =
  getEffectiveUserID <&> \case
    0 -> defaultPnetSocketPath
    n -> concat ["/run/user/", show n, "/pnet.sock"]

pnetSocket :: IO Socket
pnetSocket = socket AF_UNIX Stream defaultProtocol

pnetSocketAddr :: IO SockAddr
pnetSocketAddr = do
  defaultPath <- defaultUserPnetSocketPath
  customPath <- lookupEnv "PNET_SOCKET_PATH"
  let path = fromMaybe defaultPath customPath
  traceM ("comunicating over \"" <> path <> "\"")
  pure $ SockAddrUnix path

withPnetSocket :: (Socket -> IO a) -> IO a
withPnetSocket = bracket pnetSocket close

instance Serialize Transport

instance Serialize TunnelMessage

instance Serialize NodeToManagerMessage

instance Serialize ManagerToNodeMessage
