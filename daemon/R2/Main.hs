import Network.Socket (bind, listen)
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import R2.Daemon.Bus
import R2.Daemon.Coordinator
import R2.Daemon.Sockets.Accept
import R2.Options
import R2.Peer
import R2.Socket
import System.Exit
import System.Posix
import R2.Daemon.Storage

main :: IO ()
main =
  let runTransport f s = closeToSocket timeout s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s =
        acceptToIO s
          . runScopedBundle @(Transport Message Message) (runTransport $ serializeOutput . deserializeInput)
      runProcess = scopedProcToIOFinal bufferSize
      run s =
        runFinal @IO
          . ignoreTrace
          . asyncToIOFinal
          . resourceToIOFinal
          . embedToFinal @IO
          . failToEmbed @IO
          . runProcess
          . runSocket s
          . storageToIO
          . interpretRace
          . interpretBusTBM bufferSize timeout
          . traceToStdoutBuffered
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withR2Socket \s -> do
        (Options maybeSocketPath daemon self cmd) <- parse
        addr <- r2SocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon . run s $ r2d self cmd
