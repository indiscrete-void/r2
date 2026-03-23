import Control.Monad
import Debug.Trace qualified as Debug
import R2 (emptyAddrSet)
import R2.Client
import R2.Client.Options
import R2.Peer.FilePaths
import System.IO
import Text.Printf

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  case command of
    SomeCommandOffline command -> r2cOfflineIO command
    SomeCommandOnline command -> do
      socketPath <- resolveSocketPath maybeSocketPath
      Debug.traceM (printf "comunicating over %s" socketPath)
      r2cIO stderr verbosity emptyAddrSet socketPath command
