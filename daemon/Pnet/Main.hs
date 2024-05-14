import Control.Monad
import Network.Socket (bind, listen)
import Pnet
import Pnet.Networking
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
import System.Exit
import System.Posix
import Text.Printf qualified as Text
import Transport.Maybe

handleNodeMsgs :: (Member (Input NodeToNodeMessage) r, Member (Output NodeToNodeMessage) r, Member Trace r) => Sem r ()
handleNodeMsgs = forever $ input >>= go
  where
    go Ping = traceTagged "Ping" "Pong" >> output Pong
    go Pong = traceTagged "Pong" "doing nothing"
    go _ = _

pnetnd :: (Member (Input NodeToNodeMessage) r, Member (Output NodeToNodeMessage) r, Member Trace r) => Sem r ()
pnetnd = trace "sending Ping" >> output Ping >> handleNodeMsgs

type State = [NodeID]

initialState :: State
initialState = []

daemonNode :: (Member Fail r, Member (Socket ManagerToNodeMessage NodeToManagerMessage s) r, Member Decoder r, Member Trace r) => s -> Node (Sem r) NodeToNodeMessage NodeToNodeMessage
daemonNode s =
  unserializeNode $
    Node
      { nodeSend = send . DaemonNodeData . TunnelMessage . Just,
        nodeRecv =
          let managerNodeData (ManagerNodeData (TunnelMessage maybeStr)) = maybeStr
              managerNodeData _ = _
           in ((recv >>= maybeFailEOF) >>= maybeFailEOF . managerNodeData)
      }
  where
    (Node send recv) = sockNode s

handleManagerMsgs :: (Member Trace r, Members (SocketEffects ManagerToNodeMessage NodeToManagerMessage) r, Member (Socket ManagerToNodeMessage NodeToManagerMessage s) r, Member Fail r, Member Decoder r, Member (AtomicState State) r) => s -> Sem r ()
handleManagerMsgs s = handle go >> close
  where
    go ListNodes = do
      nodeList <- atomicGet
      traceTagged "ListNodes" (Text.printf "responding with `%s`" (show nodeList))
      output (NodeList nodeList)
    go (NodeAvailability transport maybeNodeID) = do
      let connectedDaemonNode = daemonNode s
      case maybeNodeID of
        Just nodeID -> atomicModify' (nodeID :) >> traceTagged "NodeAvailability" (Text.printf "%s connected over `%s`" (show nodeID) (show transport))
        Nothing -> traceTagged "NodeAvailability" (Text.printf "unknown node connected over `%s`" (show transport))
      nodeToIO connectedDaemonNode pnetnd
    go _ = _

pnetd :: (Member Trace r, Member (Socket ManagerToNodeMessage NodeToManagerMessage s) r, Member (AtomicState State) r, Member Fail r, Member Decoder r, Member Async r) => Sem r ()
pnetd = handleClient \s -> ioToSock s (handleManagerMsgs s)

forkIf :: Bool -> IO () -> IO ()
forkIf True m = forkProcess m >> exitSuccess
forkIf False m = m

main :: IO ()
main =
  let runSocket server =
        sockToIO bufferSize server
          . runDecoder
          . unserializeSock @ManagerToNodeMessage @NodeToManagerMessage
      runAtomicState = void . atomicStateToIO initialState
      run server =
        runFinal @IO
          . asyncToIOFinal
          . embedToFinal @IO
          . failToEmbed @IO
          . traceToStdoutBuffered
          . runSocket server
          . runAtomicState
   in withPnetSocket \sock -> do
        (Options maybeSocketPath daemon) <- parse
        addr <- pnetSocketAddr maybeSocketPath
        bind sock addr
        listen sock 5
        forkIf daemon $ run sock pnetd
