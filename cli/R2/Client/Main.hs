import Debug.Trace qualified as Debug
import R2.Client
import R2.Client.Options
import R2.Peer
import System.IO
import Text.Printf

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  socketPath <- resolveSocketPath maybeSocketPath
  Debug.traceM (printf "comunicating over %s" socketPath)
  r2cIO stderr verbosity Nothing socketPath command
