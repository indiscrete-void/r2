import R2.Client
import R2.Client.Options

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  r2cIO verbosity Nothing maybeSocketPath command
