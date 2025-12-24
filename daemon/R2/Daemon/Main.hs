import Control.Monad
import R2.Peer
import R2.Daemon
import R2.Daemon.Options

main :: IO ()
main = do
  (Options verbosity maybeSocketPath self cmd) <- parse
  socketPath <- resolveSocketPath maybeSocketPath
  void $ r2dIO verbosity False self socketPath cmd
