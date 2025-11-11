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
import R2
import R2.Daemon
import R2.Daemon.Bus
import R2.Daemon.Node
import R2.Daemon.Options
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Options
import R2.Peer
import R2.Socket
import System.Exit
import System.Posix
import Text.Printf (printf)

logShowOptionalAddr :: Maybe Address -> String
logShowOptionalAddr (Just addr) = show addr
logShowOptionalAddr Nothing = "unknown node"

logShowNode :: Node chan -> String
logShowNode node = logShowOptionalAddr (nodeAddr node)

logToTrace :: (Member Trace r) => Verbosity -> String -> InterpreterFor (Output Log) r
logToTrace verbosity cmd = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv node msg) = traceTagged (printf "<-%s" $ logShowNode node) $ case msg of
      ReqListNodes -> trace $ printf "listing connected nodes"
      ReqConnectNode transport maybeNodeID -> trace $ printf "connecting %s over %s" (logShowOptionalAddr maybeNodeID) (show transport)
      ReqTunnelProcess -> trace (printf "tunneling `%s`" cmd)
      MsgRouteTo RouteTo {..} -> when (verbosity > 1) $ trace $ printf "routing `%s` to %s" (show routeToData) (show routeToNode)
      MsgRoutedFrom RoutedFrom {..} -> when (verbosity > 1) $ trace $ printf "`%s` routed from %s" (show routedFromData) (show routedFromNode)
      msg -> when (verbosity > 0) $ trace $ printf "trace: unknown msg %s" (show msg)
    go (LogSend node msg) = traceTagged (printf "->%s" (logShowNode node)) $ case msg of
      msg@(ResNodeList _) -> trace (show msg)
      msg -> when (verbosity > 1) $ trace (show msg)
    go (LogDisconnected node) = trace $ printf "%s disconnected" (logShowNode node)
    go (LogError node err) = trace $ printf "%s error: %s" (logShowNode node) err

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
          $ r2d self cmd
