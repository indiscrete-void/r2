import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket hiding (close)
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Client
import R2.Client.Options
import R2.Options
import R2.Peer
import R2.Socket
import System.IO
import System.Random.Stateful
import Text.Printf (printf)

outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
outputToCLI = runOutputSem (embed . putStrLn)

runStandardIO :: (Member (Embed IO) r) => Int -> InterpretersFor (Transport ByteString ByteString) r
runStandardIO bufferSize = closeToIO stdout . outputToIO stdout . inputToIO bufferSize stdin

main :: IO ()
main =
  let run verbosity s =
        runFinal
          . asyncToIOFinal
          . embedToFinal @IO
          . traceIOExceptions @IOException
          . failToEmbed @IO
          -- interpreter log is ignored
          . ignoreTrace
          -- socket, std and process io
          . (runSocketIO bufferSize s . runSerialization)
          . runStandardIO bufferSize
          . scopedProcToIOFinal bufferSize
          -- log application events
          . outputToCLI
          . traceToStderrBuffered
          . logToTrace verbosity
   in withR2Socket \s -> do
        (Options verbosity command maybeSocketPath) <- parse
        gen <- initStdGen >>= newIOGenM
        self <- uniformM @Address gen
        connect s =<< r2SocketAddr maybeSocketPath
        run verbosity s $ r2c self command
