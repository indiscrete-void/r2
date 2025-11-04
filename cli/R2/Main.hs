import Data.ByteString (ByteString)
import Network.Socket hiding (close)
import Network.Socket qualified as IO
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
import R2.Options
import R2.Peer
import R2.Socket
import System.IO
import System.Random.Stateful
import Text.Printf (printf)

logToTrace :: (Member Trace r) => InterpreterFor (Output Log) r
logToTrace = runOutputSem \case
  (LogMe me) -> trace $ printf "me: %s" (show me)
  (LogLocalDaemon them) -> trace $ printf "communicating with %s" (show them)
  (LogInput transport bs) -> trace $ printf "<-%s: %s" (show transport) (show bs)
  (LogOutput transport bs) -> trace $ printf "->%s: %s" (show transport) (show bs)
  (LogRecv addr bs) -> trace $ printf "<-%s: %s" (show addr) (show bs)
  (LogSend addr bs) -> trace $ printf "->%s: %s" (show addr) (show bs)
  (LogAction addr action) -> trace $ printf "running %s on %s" (show action) (show addr)

outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
outputToCLI = runOutputSem (embed . putStrLn)

runStandardIO :: (Member (Embed IO) r) => InterpretersFor (Transport ByteString ByteString) r
runStandardIO = closeToIO stdout . outputToIO stdout . inputToIO bufferSize stdin

main :: IO ()
main =
  let run s =
        runFinal
          . asyncToIOFinal
          . embedToFinal @IO
          . failToEmbed @IO
          -- interpreter log is ignored
          . ignoreTrace
          -- socket, std and process io
          . (runSocketIO bufferSize s . runSerialization)
          . runStandardIO
          . scopedProcToIOFinal bufferSize
          -- log application events
          . outputToCLI
          . traceToStderrBuffered
          . logToTrace
   in withR2Socket \s -> do
        (Options command maybeSocketPath) <- parse
        gen <- initStdGen >>= newIOGenM
        self <- uniformM @Address gen
        connect s =<< r2SocketAddr maybeSocketPath
        run s $ r2c self command
