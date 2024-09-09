import Data.ByteString (ByteString)
import Network.Socket hiding (close)
import Pnet
import Pnet.Client
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Transport
import System.IO

main :: IO ()
main =
  let runUnserialized = runDecoder . deserializeInput @Response . serializeOutput @Handshake . deserializeInput @(RouteTo (Maybe ByteString)) . serializeOutput @(RoutedFrom (Maybe ByteString))
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      run s = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport s . runStdio
   in withPnetSocket \s -> do
        (Options command maybeSocketPath) <- parse
        connect s =<< pnetSocketAddr maybeSocketPath
        run s $ pnet command
