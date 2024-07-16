module Pnet
  ( Handshake (..),
    Response (..),
    pnetSocketAddr,
    pnetSocket,
    withPnetSocket,
    timeout,
    bufferSize,
    queueSize,
    Transport (..),
  )
where

import Control.Applicative ((<|>))
import Control.Exception
import Data.Maybe
import Data.Serialize
import Debug.Trace
import GHC.Generics
import Network.Socket
import Pnet.Routing
import System.Environment
import System.Posix

data Transport
  = Stdio
  | Process String
  deriving stock (Show, Generic)

data Handshake where
  ListNodes :: Handshake
  ConnectNode :: Transport -> Maybe Address -> Handshake
  deriving stock (Show, Generic)

data Response where
  NodeList :: [Address] -> Response
  deriving stock (Show, Generic)

timeout :: Int
timeout = 16384

bufferSize :: Int
bufferSize = 8192

queueSize :: Int
queueSize = 16

defaultPnetSocketPath :: FilePath
defaultPnetSocketPath = "/run/pnet.sock"

defaultUserPnetSocketPath :: IO FilePath
defaultUserPnetSocketPath = go <$> getEffectiveUserID
  where
    go 0 = defaultPnetSocketPath
    go n = concat ["/run/user/", show n, "/pnet.sock"]

pnetSocket :: IO Socket
pnetSocket = do
  s <- socket AF_UNIX Stream defaultProtocol
  setSocketOption s RecvTimeOut (timeout * 1024)
  setSocketOption s SendTimeOut (timeout * 1024)
  pure s

pnetSocketAddr :: Maybe FilePath -> IO SockAddr
pnetSocketAddr customPath = do
  defaultPath <- defaultUserPnetSocketPath
  extraCustomPath <- lookupEnv "PNET_SOCKET_PATH"
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  traceM ("comunicating over \"" <> path <> "\"")
  pure $ SockAddrUnix path

withPnetSocket :: (Socket -> IO a) -> IO a
withPnetSocket = bracket pnetSocket (`gracefulClose` timeout)

instance Serialize Transport

instance Serialize Handshake

instance Serialize Response
