import R2.Daemon
import R2.Daemon.Options

main :: IO ()
main = do
  (Options verbosity maybeSocketPath daemon self cmd) <- parse
  r2dIO verbosity daemon self maybeSocketPath cmd
