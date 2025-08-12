import Control.Monad
import Network.Socket (bind, listen)
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Socket.Accept
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Bus
import R2.Options
import R2.Peer
import R2.Peer.Daemon
import System.Exit
import System.Posix

main :: IO ()
main =
  let runTransport f s = closeToSocket timeout s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s =
        acceptToIO s
          . runScopedBundle @(TransportEffects Message Message) (runTransport $ serializeOutput . deserializeInput)
      runAtomicState = void . atomicStateToIO initialState
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
          . runAtomicState
          . interpretRace
          . interpretRecvFromTBMQueue
          . traceToStdoutBuffered
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withR2Socket \s -> do
        (Options maybeSocketPath daemon self cmd) <- parse
        addr <- r2SocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon . run s $ r2d self cmd
