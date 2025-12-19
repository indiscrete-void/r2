import Network.Socket hiding (close)
import R2.Client
import R2.Client.Options
import R2.Peer

main :: IO ()
main = do
  (Options verbosity command maybeSocketPath) <- parse
  withR2Socket \s -> do
    connect s =<< r2SocketAddr maybeSocketPath
    r2cIO verbosity Nothing maybeSocketPath command
