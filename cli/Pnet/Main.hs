import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import System.IO

pnet :: (Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member Fail r, Member Trace r, Member Close r, Member Async r) => Command -> Sem r ()
pnet Ls = output ListNodes >> (inputOrFail @NodeToManagerMessage >>= traceTagged "Ls" . show)
pnet (Connect transport nodeID) =
  output (ConnectNode transport nodeID) >> case transport of
    Stdio -> async_ nodeToDaemon >> daemonToNode
    _ -> _
  where
    nodeToDaemon = transferStream (msg . Just) (msg Nothing)
      where
        msg = ManagerNodeData . TunnelMessage
    daemonToNode = handle go
      where
        go (DaemonNodeData (TunnelMessage maybeStr)) = maybe close output maybeStr
        go _ = _
pnet _ = _

main :: IO ()
main =
  let run h = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport h . runStdio
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      runTransport h = inputToIO bufferSize h . outputToIO h . runUnserialized
      runUnserialized = runDecoder . deserializeInput @NodeToManagerMessage . serializeOutput @ManagerToNodeMessage
   in withPnetSocket \sock -> do
        (Options command maybeSocketPath) <- parse
        connect sock =<< pnetSocketAddr maybeSocketPath
        h <- socketToHandle sock ReadWriteMode
        run h $ pnet command
