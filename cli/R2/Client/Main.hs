import R2.Client
import R2.Client.Options
import R2.Peer

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  socketPath <- resolveSocketPath maybeSocketPath
  r2cIO verbosity Nothing socketPath command
