module R2.Peer.FilePaths
  ( r2SocketEnv,
    resolveSocketPath,
    defaultR2KeyStorePath,
    getUsableKeyPairDir,
  )
where

import Control.Applicative (Alternative (..))
import Control.Monad
import Data.Maybe
import System.Directory
import System.Environment

r2SocketEnv :: String
r2SocketEnv = "R2_SOCKET"

permissions700 :: Permissions
permissions700 =
  setOwnerReadable True
    . setOwnerWritable True
    . setOwnerExecutable True
    . setOwnerSearchable True
    $ emptyPermissions

createDirectory700IfMissing :: FilePath -> IO ()
createDirectory700IfMissing path = do
  exists <- doesDirectoryExist path
  unless exists do
    createDirectory path
    setPermissions path permissions700

xdgR2DirsName :: String
xdgR2DirsName = "r2"

defaultUserR2SocketPath :: IO FilePath
defaultUserR2SocketPath = do
  stateDir <- getXdgDirectory XdgState xdgR2DirsName
  createDirectory700IfMissing stateDir
  pure $ stateDir <> "/" <> "r2.sock"

defaultR2KeyStorePath :: IO FilePath
defaultR2KeyStorePath = do
  dataDir <- getXdgDirectory XdgData xdgR2DirsName
  createDirectory700IfMissing dataDir
  pure dataDir

getUsableKeyPairDir :: FilePath -> IO FilePath
getUsableKeyPairDir publicKeyPath = do
  ksPath <- defaultR2KeyStorePath
  let kpPath = ksPath <> "/" <> publicKeyPath
  createDirectoryIfMissing False kpPath
  pure kpPath

resolveSocketPath :: Maybe FilePath -> IO FilePath
resolveSocketPath customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv r2SocketEnv
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  pure path
