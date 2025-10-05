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
import R2
import R2.Daemon
import R2.Daemon.Bus
import R2.Daemon.Node
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
logShowOptionalAddr Nothing = "unknwon node"

logToTrace :: (Member Trace r) => String -> InterpreterFor (Output Log) r
logToTrace cmd = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv node msg) = traceTagged (show node) $ case msg of
      ReqListNodes -> trace $ printf "listing connected nodes"
      ReqConnectNode transport maybeNodeID -> trace $ printf "connecting %s over %s" (logShowOptionalAddr maybeNodeID) (show transport)
      ReqTunnelProcess -> trace (printf "tunneling `%s`" cmd)
      MsgRouteTo RouteTo {..} -> trace $ printf "routing `%s` to %s" (show routeToData) (show routeToNode)
      MsgRoutedFrom RoutedFrom {..} -> trace $ printf "`%s` routed from %s" (show routedFromData) (show routedFromNode)
      msg -> trace $ printf "trace: unknown msg %s" (show msg)
    go (LogSend node msg) = trace $ printf "sent %s to %s" (show msg) (show node)
    go (LogDisconnected node) = trace $ printf "%s disconnected" (show node)

main :: IO ()
main =
  let runTransport f s = closeToSocket s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s =
        acceptToIO s
          . runScopedBundle @(Transport Message Message) (runTransport $ serializeOutput . deserializeInput)
      runProcess = scopedProcToIOFinal bufferSize
      run cmd s =
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
          . interpretBusTBM queueSize
          . traceToStdoutBuffered
          . logToTrace cmd
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withR2Socket \s -> do
        (Options maybeSocketPath daemon self cmd) <- parse
        addr <- r2SocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon . run cmd s $ r2d self cmd
