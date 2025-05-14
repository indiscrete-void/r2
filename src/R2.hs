module R2
  ( Handshake (..),
    Self (..),
    Response (..),
    r2SocketAddr,
    r2Socket,
    withR2Socket,
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
import R2.Routing
import System.Environment
import System.Posix

data Transport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

newtype Self = Self {unSelf :: Address}
  deriving stock (Show, Generic)

data Handshake where
  ConnectNode :: Transport -> Maybe Address -> Handshake
  ListNodes :: Handshake
  Route :: Handshake
  TunnelProcess :: Handshake
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

defaultR2SocketPath :: FilePath
defaultR2SocketPath = "/run/r2.sock"

defaultUserR2SocketPath :: IO FilePath
defaultUserR2SocketPath = go <$> getEffectiveUserID
  where
    go 0 = defaultR2SocketPath
    go n = concat ["/run/user/", show n, "/r2.sock"]

r2Socket :: IO Socket
r2Socket = do
  s <- socket AF_UNIX Stream defaultProtocol
  setSocketOption s RecvTimeOut timeout
  setSocketOption s SendTimeOut timeout
  pure s

r2SocketAddr :: Maybe FilePath -> IO SockAddr
r2SocketAddr customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv "PNET_SOCKET_PATH"
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  traceM ("comunicating over \"" <> path <> "\"")
  pure $ SockAddrUnix path

withR2Socket :: (Socket -> IO a) -> IO a
withR2Socket = bracket r2Socket close

instance Serialize Transport

instance Serialize Self

instance Serialize Handshake

instance Serialize Response
