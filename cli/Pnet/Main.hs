import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import System.IO

pnet :: (Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member Fail r, Member Trace r, Member Close r, Member Async r) => Command -> Sem r ()
pnet Ls = output ListNodes >> (inputOrFail @NodeToManagerMessage >>= traceTagged "Ls" . show)
pnet (Connect transport maybeNodeID) =
  output (ConnectNode transport maybeNodeID) >> case transport of
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
  let run s = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport s . runStdio
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runUnserialized = runDecoder . deserializeInput @NodeToManagerMessage . serializeOutput @ManagerToNodeMessage
   in withPnetSocket \s -> do
        (Options command maybeSocketPath) <- parse
        connect s =<< pnetSocketAddr maybeSocketPath
        run s $ pnet command
