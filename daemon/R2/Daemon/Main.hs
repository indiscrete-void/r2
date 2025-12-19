import Control.Monad
import R2.Daemon
import R2.Daemon.Options

main :: IO ()
main = do
  (Options verbosity maybeSocketPath self cmd) <- parse
  void $ r2dIO verbosity False self maybeSocketPath cmd
