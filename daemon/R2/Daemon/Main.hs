import R2
import R2.Daemon
import R2.Daemon.Options
import R2.Peer
import Text.Printf

main :: IO ()
main = do
  (Options verbosity maybeSocketPath self) <- parse
  socketPath <- resolveSocketPath maybeSocketPath
  printf "comunicating over %s" socketPath
  r2dToIO verbosity socketPath $ r2d (NameLabelAddr self)
