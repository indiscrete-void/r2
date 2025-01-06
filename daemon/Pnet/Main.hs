import Control.Constraint
import Control.Monad
import Data.ByteString (ByteString)
import Data.Serialize
import Network.Socket (bind, listen)
import Pnet
import Pnet.Daemon
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run, send)
import Polysemy.Any
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Socket.Accept
import Polysemy.Transport
import System.Exit
import System.Posix

main :: IO ()
main =
  let runTransport f s = closeToSocket timeout s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s =
        acceptToIO s
          . runScopedBundle @(Any (Show :&: Serialize)) (runTransport $ serializeAnyOutput . deserializeAnyInput)
      runAtomicState = void . atomicStateToIO initialState
      runProcess = scopedProcToIOFinal bufferSize
      run s =
        runFinal @IO
          . asyncToIOFinal
          . resourceToIOFinal
          . runDecoder
          . embedToFinal @IO
          . failToEmbed @IO
          . traceToStdoutBuffered
          . runProcess
          . runSocket s
          . runAtomicState
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withPnetSocket \s -> do
        (Options maybeSocketPath daemon self cmd) <- parse
        addr <- pnetSocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon . run s $ pnetd self cmd
