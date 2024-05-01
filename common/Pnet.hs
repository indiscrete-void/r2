module Pnet (pnetSocketAddr, pnetSocket, withPnetSocket, bufferSize) where

import Control.Exception
import Data.Maybe
import Network.Socket
import System.Environment

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
