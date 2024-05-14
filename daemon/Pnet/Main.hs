import Data.Functor
import Network.Socket (bind, listen)
import Pnet
import Pnet.Options
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import Text.Printf qualified as Text

type State = [(Transport, NodeID)]

initialState :: State
initialState = []

pnetd :: (Member Trace r, Member (Socket ManagerToNodeMessage NodeToManagerMessage s) r, Member Async r, Member (AtomicState State) r) => Sem r ()
pnetd = handleClient @ManagerToNodeMessage @NodeToManagerMessage $ handle go >> close
  where
    go ListNodes = do
      nodeList <- map snd <$> atomicGet @State
      traceTagged "ListNodes" (Text.printf "responding with `%s`" (show nodeList))
      output (NodeList nodeList)
    go (NodeAvailability transport maybeNode) = case maybeNode of
      Just node -> atomicModify' ((transport, node) :) >> traceTagged "NodeAvailability" (Text.printf "%s connected over `%s`" (show node) (show transport))
      Nothing -> traceTagged "NodeAvailability" (Text.printf "unknown node connected over `%s`" (show transport))

main :: IO ()
main =
  let runSocket server =
        sockToIO bufferSize server
          . runDecoder
          . unserializeSock @ManagerToNodeMessage @NodeToManagerMessage
      runAtomicState = void . atomicStateToIO initialState
      run server = runFinal @IO . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStdout . runSocket server . runAtomicState
   in withPnetSocket \sock -> do
        (Options maybeSocketPath) <- parse
        addr <- pnetSocketAddr maybeSocketPath
        bind sock addr
        listen sock 5
        run sock pnetd
