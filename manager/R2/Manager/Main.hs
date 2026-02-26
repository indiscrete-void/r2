import R2.DSL
import R2.Manager.Options (parse)
import System.IO
import Text.Printf

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  config <- parse
  printf "comunicating over %s" $ daemonSocketPath config
  runManagedDaemon config
