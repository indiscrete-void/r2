module R2.Peer.Daemon (State, initialState, tunnelProcess, r2d) where

import Control.Monad.Extra
import Data.List qualified as List
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.Socket.Accept
import Polysemy.Sockets
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Bus
import R2
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

-- data
data ConnTransport = R2 Address | Pipe Address ProcessTransport | Socket
  deriving stock (Eq, Show)

data NewConnection = NewConnection
  { newConnAddr :: Maybe Address,
    newConnTransport :: ConnTransport
  }

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: NodeBusChan chan
  }
  deriving stock (Eq, Show)

-- state
type State chan = [Connection chan]

initialState :: State s
initialState = []

withReverse :: ([a] -> [b]) -> [a] -> [b]
withReverse f = reverse . f . reverse

stateAddNode :: (Member (AtomicState (State q)) r) => Connection q -> Sem r ()
stateAddNode nodeData = atomicModify' $ withReverse (nodeData :)

stateDeleteNode :: (Member (AtomicState (State q)) r) => Connection q -> Sem r ()
stateDeleteNode node = atomicModify' $ withReverse (List.filter (\xNode -> connAddr xNode == connAddr node))

stateLookupNode :: (Member (AtomicState (State q)) r) => Address -> Sem r (Maybe (Connection q))
stateLookupNode addr = List.find ((addr ==) . connAddr) <$> atomicGet

stateReflectNode :: (Member (AtomicState (State q)) r, Member Trace r, Member Resource r) => Connection q -> Sem r c -> Sem r c
stateReflectNode node = bracket_ addNode delNode
  where
    addNode = trace (Text.printf "storing %s" $ show $ connAddr node) >> stateAddNode node
    delNode = trace (Text.printf "forgetting %s" $ show $ connAddr node) >> stateDeleteNode node

-- messages
tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Trace r,
    Member Async r
  ) =>
  String ->
  Sem r ()
tunnelProcess cmd = traceTagged "tunnel" $ execIO (ioShell cmd) ioToMsg

listNodes :: (Member (AtomicState (State s)) r, Member (Output Message) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map connAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (ResNodeList nodeList)

connectNode ::
  ( Members (Transport Message Message) r,
    Member (NodeBus NewConnection q Message) r,
    Member (Bus q Message) r,
    Member Trace r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode router transport maybeNewNodeID =
  msgToIO $ nodeBusToIO (NewConnection maybeNewNodeID (Pipe router transport))

handleRouteTo :: (Member (NodeBus Address chan Message) r, Member (Bus chan Message) r) => Address -> RouteTo Message -> Sem r ()
handleRouteTo = r2 (\reqAddr -> useNodeBusChan ToWorld reqAddr . putChan . Just . MsgRoutedFrom)

handleRoutedFrom :: (Member (NodeBus Address chan Message) r, Member (Bus chan Message) r) => RoutedFrom Message -> Sem r ()
handleRoutedFrom (RoutedFrom routedFromNode routedFromData) = useNodeBusChan FromWorld routedFromNode $ putChan (Just routedFromData)

handleMsg ::
  ( Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (Transport Message Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r,
    Member Trace r
  ) =>
  String ->
  Connection q ->
  Message ->
  Sem r ()
handleMsg cmd Connection {..} = \case
  ReqListNodes -> listNodes
  (ReqConnectNode transport maybeNodeID) -> connectNode connAddr transport maybeNodeID
  ReqTunnelProcess -> tunnelProcess cmd
  MsgRouteTo routeTo -> handleRouteTo connAddr routeTo
  MsgRoutedFrom routedFrom -> handleRoutedFrom routedFrom
  msg -> fail $ "unexpected message: " <> show msg

-- networking
exchangeSelves ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  Sem r Address
exchangeSelves self maybeKnownAddr = do
  output (MsgSelf $ Self self)
  (Just (Self addr)) <- msgSelf <$> inputOrFail
  whenJust maybeKnownAddr \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (Text.printf "address mismatch")
  pure addr

r2nd ::
  ( Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (NodeBus Address chan Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member (Bus chan Message) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member Trace r,
    Member Fail r,
    Member Resource r
  ) =>
  String ->
  Connection chan ->
  Sem r ()
r2nd cmd conn@(Connection {..}) =
  stateReflectNode conn $
    traceTagged ("r2nd " <> show connAddr) $
      handle (handleMsg cmd conn)

runR2NodeBus ::
  ( Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Trace r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  String ->
  Address ->
  InterpreterFor (NodeBus Address chan Message) r
runR2NodeBus self cmd router = interpret \case
  NodeBusGetChan addr -> do
    storedNode <- stateLookupNode addr
    case storedNode of
      Just node -> pure $ connChan node
      Nothing -> do
        chan <- nodeBusMakeChan
        async_ $ routeToChan (nodeBusChan ToWorld chan) addr
        let conn = Connection addr (R2 router) chan
        ioToNodeBusChan chan $ makeNode self cmd conn
        pure chan
  where
    routeToChan ::
      ( Member (AtomicState (State chan)) r,
        Member (Bus chan Message) r,
        Member Fail r
      ) =>
      chan ->
      Address ->
      Sem r ()
    routeToChan chan addr =
      busChan chan $ do
        (Just routerNode) <- stateLookupNode router
        let routerChan = nodeBusChan ToWorld (connChan routerNode)
        takeChan >>= \case
          Just i -> do
            busChan routerChan (putChan $ Just $ MsgRouteTo $ RouteTo addr i)
              >> routeToChan chan addr
          Nothing -> mempty

makeNode ::
  ( Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Bus chan Message) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member Trace r,
    Member Fail r,
    Member Resource r
  ) =>
  Address ->
  String ->
  Connection chan ->
  Sem r ()
makeNode self cmd conn@(Connection {..}) = do
  async_ $
    runNewNodeBus self cmd $
      runR2NodeBus self cmd connAddr $
        r2nd cmd conn

runNewNodeBus ::
  ( Member (Bus chan Message) r,
    Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Async r,
    Member Trace r,
    Member Resource r
  ) =>
  Address ->
  String ->
  InterpreterFor (NodeBus NewConnection chan Message) r
runNewNodeBus self cmd = interpret \case
  NodeBusGetChan NewConnection {..} -> do
    chan <- nodeBusMakeChan
    async_ $ ioToNodeBusChan chan $ do
      addr <- exchangeSelves self newConnAddr
      let conn = Connection addr newConnTransport chan
      makeNode self cmd conn
    pure chan

r2sd ::
  ( Member (Accept sock) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member Async r
  ) =>
  Sem r ()
r2sd =
  foreverAcceptAsync \s -> do
    socket @Message @Message s $ nodeBusToIO (NewConnection Nothing Socket)

r2d ::
  forall sock chan r.
  ( Member (Accept sock) r,
    Member (AtomicState (State chan)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Resource r,
    Member Async r,
    Member Trace r,
    Member Fail r
  ) =>
  Address ->
  String ->
  Sem r ()
r2d self cmd = runNewNodeBus self cmd r2sd
