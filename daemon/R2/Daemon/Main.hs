import Control.Exception
import Control.Monad
import Network.Socket (bind, listen)
import Network.Socket qualified as IO
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import R2.Bus
import R2.Daemon
import R2.Daemon.Options
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Peer
import R2.Socket
import System.Exit
import System.Posix

runScopedSocket :: (Member (Embed IO) r, Member Trace r, Member Fail r) => Int -> InterpreterFor (Scoped IO.Socket (Bundle (Transport Message Message))) r
runScopedSocket bufferSize =
  runScopedBundle @(Transport Message Message)
    ( \s ->
        runSocketIO bufferSize s
          . runSerialization
          . raise2Under @ByteInputWithEOF
          . raise2Under @ByteOutput
    )

runServerSocket ::
  (Member (Embed IO) r, Member Fail r, Member Trace r) =>
  Int ->
  IO.Socket ->
  InterpretersFor
    '[ Scoped IO.Socket (Bundle (Transport Message Message)),
       Accept IO.Socket
     ]
    r
runServerSocket bufferSize s = acceptToIO s . runScopedSocket bufferSize

forkIf :: Bool -> IO () -> IO ()
forkIf True m = forkProcess m >> exitSuccess
forkIf False m = m

main :: IO ()
main =
  let run verbosity cmd s =
        runFinal @IO
          . interpretRace
          . asyncToIOFinal
          . resourceToIOFinal
          . embedToFinal @IO
          . traceIOExceptions @IOException
          . interpretBusTBM queueSize
          . failToEmbed @IO
          -- ignore interpreter logs
          . ignoreTrace
          -- process and socket io
          . scopedProcToIOFinal bufferSize
          . runServerSocket bufferSize s
          -- AtomicRef storage
          . storageToIO
          -- log application events
          . traceToStdoutBuffered
          . logToTrace verbosity cmd
   in withR2Socket \s -> do
        (Options verbosity maybeSocketPath daemon self cmd) <- parse
        addr <- r2SocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon
          . run verbosity cmd s
          $ r2Socketd self cmd
