module R2.Peer.FilePaths
  ( r2SocketEnv,
    resolveSocketPath,
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

defaultUserR2SocketPath :: IO FilePath
defaultUserR2SocketPath = do
  stateDir <- getXdgDirectory XdgState "r2"
  createDirectory700IfMissing stateDir
  pure $ stateDir <> "/" <> "r2.sock"

resolveSocketPath :: Maybe FilePath -> IO FilePath
resolveSocketPath customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv r2SocketEnv
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  pure path
