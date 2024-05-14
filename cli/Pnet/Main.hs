import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Polysemy hiding (run)
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import System.IO

pnet :: (Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member Close r, Member Fail r, Member Trace r) => Command -> Sem r ()
pnet command = go command >> close
  where
    go Ls = output ListNodes >> (inputOrFail @NodeToManagerMessage >>= traceTagged "Ls" . show)
    go (Connect transport node) = output $ NodeAvailability transport node
    go _ = _

main :: IO ()
main =
  let run h = runM . failToEmbed @IO . traceToStderrBuffered . runTransport h
      runTransport h = inputToIO bufferSize h . outputToIO h . closeToIO h . runUnserialized
      runUnserialized = runDecoder . deserializeInput @NodeToManagerMessage . serializeOutput @ManagerToNodeMessage
   in withPnetSocket \sock -> do
        (Options command maybeSocketPath) <- parse
        connect sock =<< pnetSocketAddr maybeSocketPath
        h <- socketToHandle sock ReadWriteMode
        run h $ pnet command
