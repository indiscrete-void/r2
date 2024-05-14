import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Tagged
import Polysemy.Trace
import Polysemy.Transport
import System.IO

connectNodeAndDaemon :: (Member ByteInputWithEOF r, Member ByteOutput r, Member Fail r, Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member (Tagged 'Stdio Close) r, Member Async r, Member Trace r) => Transport -> Sem r ()
connectNodeAndDaemon Stdio = async_ nodeToDaemon >> daemonToNode
  where
    nodeToDaemon = transferStream (msg . Just) (msg Nothing)
      where
        msg = ManagerNodeData . TunnelMessage
    daemonToNode = handle go
      where
        go (DaemonNodeData (TunnelMessage maybeStr)) = tag @'Stdio @Close (maybe close output maybeStr)
        go _ = _
connectNodeAndDaemon _ = _

pnet :: (Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member Close r, Member Fail r, Member Trace r, Member (Tagged 'Stdio Close) r, Member Async r) => Command -> Sem r ()
pnet command = go command >> close
  where
    go Ls = output ListNodes >> (inputOrFail @NodeToManagerMessage >>= traceTagged "Ls" . show)
    go (Connect transport node) = output (NodeAvailability transport node) >> connectNodeAndDaemon transport
    go _ = _

main :: IO ()
main =
  let run h = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport h . runStdio
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . (closeToIO stdout . untag @'Stdio @Close)
      runTransport h = inputToIO bufferSize h . outputToIO h . closeToIO h . runUnserialized
      runUnserialized = runDecoder . deserializeInput @NodeToManagerMessage . serializeOutput @ManagerToNodeMessage
   in withPnetSocket \sock -> do
        (Options command maybeSocketPath) <- parse
        connect sock =<< pnetSocketAddr maybeSocketPath
        h <- socketToHandle sock ReadWriteMode
        run h $ pnet command
