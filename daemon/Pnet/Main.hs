import Network.Socket (bind, listen)
import Pnet
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Scoped
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport

pnetd :: (Member Trace r, Member (Scoped_ (Socket ManagerToNodeMessage NodeToManagerMessage)) r, Member Async r) => Sem r ()
pnetd = handleClient @ManagerToNodeMessage @NodeToManagerMessage $ handle go >> close
  where
    go ListNodes = trace "ListNodes: responding with `[]`" >> output (NodeList [])
    go (Other _) = _

main :: IO ()
main =
  let runSocket server =
        scopedSockToIO bufferSize server
          . runDecoder
          . unserializeScopedSock @ManagerToNodeMessage @NodeToManagerMessage
      run server = runFinal @IO . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStdout . runSocket server
   in withPnetSocket \sock -> do
        addr <- pnetSocketAddr
        bind sock addr
        listen sock 5
        run sock pnetd
