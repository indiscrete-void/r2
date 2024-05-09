import Data.Functor
import Network.Socket (bind, listen)
import Pnet
import Pnet.Polysemy.Trace
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Fail
import Polysemy.Scoped
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import Text.Printf qualified as Text

type State = [(NodeID, Transport)]

initialState :: State
initialState = []

pnetd :: (Member Trace r, Member (Scoped_ (Socket ManagerToNodeMessage NodeToManagerMessage)) r, Member Async r, Member (AtomicState State) r) => Sem r ()
pnetd = handleClient @ManagerToNodeMessage @NodeToManagerMessage $ handle go >> close
  where
    go ListNodes = do
      nodeList <- map fst <$> atomicGet @State
      traceTagged "ListNodes" (Text.printf "responding with %s" (show nodeList))
      output (NodeList nodeList)
    go (NodeAvailability node transport) =
      atomicModify' ((node, transport) :)
        >> traceTagged "NodeAvailability" (Text.printf "%s connected over %s" node (show transport))
    go (Other _) = _

main :: IO ()
main =
  let runSocket server =
        scopedSockToIO bufferSize server
          . runDecoder
          . unserializeScopedSock @ManagerToNodeMessage @NodeToManagerMessage
      runAtomicState = void . atomicStateToIO initialState
      run server = runFinal @IO . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStdout . runSocket server . runAtomicState
   in withPnetSocket \sock -> do
        addr <- pnetSocketAddr
        bind sock addr
        listen sock 5
        run sock pnetd
