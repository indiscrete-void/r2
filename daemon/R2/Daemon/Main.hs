import Control.Monad
import R2.Daemon
import R2.Daemon.Options
import R2.Peer

main :: IO ()
main = do
  (Options verbosity maybeSocketPath self) <- parse
  socketPath <- resolveSocketPath maybeSocketPath
  void $ r2dIO verbosity False self socketPath
