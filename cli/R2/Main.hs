import Network.Socket hiding (close)
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Serialize
import R2.Socket
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Options
import R2.Peer
import R2.Client
import System.IO
import System.Random.Stateful

main :: IO ()
main =
  let runUnserialized = deserializeInput . serializeOutput
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      run s = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . ignoreTrace . runTransport s . runStdio . scopedProcToIOFinal bufferSize . traceToStderrBuffered
   in withR2Socket \s -> do
        (Options command maybeSocketPath) <- parse
        gen <- initStdGen >>= newIOGenM
        self <- uniformM @Address gen
        connect s =<< r2SocketAddr maybeSocketPath
        run s $ r2c self command
