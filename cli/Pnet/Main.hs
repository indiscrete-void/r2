import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Pnet.Polysemy.Trace
import Polysemy hiding (run)
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import System.IO

pnet :: (Member (InputWithEOF NodeToManagerMessage) r, Member (Output ManagerToNodeMessage) r, Member Close r, Member Fail r, Member Trace r) => Command -> Sem r ()
pnet command = go command >> close
  where
    go Ls = output ListNodes >> (inputOrFail @NodeToManagerMessage >>= traceTagged "Ls" . show)
    go _ = _

main :: IO ()
main =
  let run h = runM . failToEmbed @IO . traceToStderr . runTransport h
      runTransport h = inputToIO bufferSize h . outputToIO h . closeToIO h . runUnserialized
      runUnserialized = runDecoder . deserializeInput @NodeToManagerMessage . serializeOutput @ManagerToNodeMessage
   in withPnetSocket \sock -> do
        connect sock =<< pnetSocketAddr
        h <- socketToHandle sock ReadWriteMode
        (Options command) <- parse
        run h $ pnet command
