import Network.Socket hiding (close)
import Pnet
import Pnet.Client
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import System.IO
import System.Random.Stateful
import Text.Printf (hPrintf)

main :: IO ()
main =
  let runUnserialized = runDecoder . deserializeAnyInput . serializeAnyOutput
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      run s = runFinal . ignoreTrace . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . runTransport s . runStdio . scopedProcToIOFinal bufferSize . traceToStderrBuffered
   in withPnetSocket \s -> do
        (Options command maybeSocketPath) <- parse
        gen <- initStdGen >>= newIOGenM
        self <- uniformM @Address gen
        hPrintf stderr "me: %s\n" $ show self
        connect s =<< pnetSocketAddr maybeSocketPath
        run s $ pnet self command
