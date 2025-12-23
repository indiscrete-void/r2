import R2.Client.Options
import R2.Client

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  r2cIO verbosity Nothing maybeSocketPath command
