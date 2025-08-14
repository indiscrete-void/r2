module R2.Peer.Daemon (State, initialState, r2d) where

import Control.Monad.Extra
import Data.List qualified as List
import Data.Maybe
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

data NodeIdentity = Partial Address | Full Address
  deriving stock (Eq, Show)

data NodeData s = NodeData
  { nodeDataTransport :: NodeTransport s,
    nodeDataAddr :: Address
  }
  deriving stock (Eq, Show)

data NodeTransport s = Sock s | Pipe Transport Address | R2 Address
  deriving stock (Eq, Show)

type State s = [NodeData s]

initialState :: State s
initialState = []

withReverse :: ([a] -> [b]) -> [a] -> [b]
withReverse f = reverse . f . reverse

stateAddNode :: (Member (AtomicState (State s)) r) => NodeData s -> Sem r ()
stateAddNode nodeData = atomicModify' $ withReverse (nodeData :)

stateDeleteNode :: (Member (AtomicState (State s)) r, Eq s) => NodeData s -> Sem r ()
stateDeleteNode nodeData = atomicModify' $ withReverse (List.delete nodeData)

stateLookupNode :: (Member (AtomicState (State s)) r) => Address -> Sem r (Maybe (NodeData s))
stateLookupNode addr = List.find ((== addr) . nodeDataAddr) <$> atomicGet

stateReflectNode :: (Show s, Eq s, Member (AtomicState (State s)) r, Member Trace r, Member Resource r) => NodeData s -> Sem r c -> Sem r c
stateReflectNode nodeData = bracket_ addNode delNode
  where
    addNode = trace (Text.printf "storing %s" $ show nodeData) >> stateAddNode nodeData
    delNode = trace (Text.printf "forgetting %s" $ show nodeData) >> stateDeleteNode nodeData

runNodeOutput ::
  ( Member (AtomicState (State s)) r,
    Member (Sockets Message Message s) r,
    Member Trace r,
    Member Fail r
  ) =>
  NodeData s ->
  InterpreterFor (Output Message) r
runNodeOutput (NodeData transport addr) = case transport of
  Sock s -> socketOutput s
  Pipe _ router -> \m -> do
    (Just routerData) <- stateLookupNode router
    runNodeOutput routerData
      . runMsgOutput
      . raiseUnder @(Output Message)
      $ m
  R2 router -> \m -> do
    (Just routerData) <- stateLookupNode router
    runNodeOutput routerData
      . runR2Output addr
      . raiseUnder @(Output Message)
      $ m

interpretSendToState ::
  ( Member (Sockets Message Message s) r,
    Member (AtomicState (State s)) r,
    Member Fail r,
    Member Trace r
  ) =>
  InterpreterFor (SendTo Address Message) r
interpretSendToState = runScopedNew \addr m -> do
  (Just nodeData) <- stateLookupNode addr
  runNodeOutput nodeData m

tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (TransportEffects Message Message) r,
    Member Trace r,
    Member Async r
  ) =>
  String ->
  Address ->
  Sem r ()
tunnelProcess cmd addr = traceTagged ("tunnel " <> show addr) $ execIO (ioShell cmd) ioToMsg

listNodes :: (Member (AtomicState (State s)) r, Member (Output Message) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map nodeDataAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (ResNodeList nodeList)

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

connectNode ::
  ( Members (TransportEffects Message Message) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (AtomicState (State s)) r,
    Member (SendTo Address Message) r,
    Member (RecvFrom Address Message) r,
    Member Trace r,
    Member Fail r,
    Member Resource r,
    Member Async r,
    Show s,
    Eq s
  ) =>
  Address ->
  String ->
  Address ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode self cmd router transport maybeNewNodeID = msgToIO do
  addr <- exchangeSelves self maybeNewNodeID
  let nodeData = NodeData (Pipe transport router) addr
  runDefaultNodeHandler self cmd nodeData

handleMsg ::
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (TransportEffects Message Message) r,
    Member (SendTo Address Message) r,
    Member (RecvFrom Address Message) r,
    Member Resource r,
    Member Fail r,
    Member Async r,
    Member Trace r,
    Show s,
    Eq s
  ) =>
  Address ->
  String ->
  NodeData s ->
  Message ->
  Sem r ()
handleMsg self cmd (NodeData _ addr) = \case
  ReqListNodes -> listNodes
  (ReqConnectNode transport maybeNodeID) -> connectNode self cmd addr transport maybeNodeID
  ReqTunnelProcess -> tunnelProcess cmd addr
  MsgRouteTo routeTo -> r2Sem (\reqAddr -> sendTo reqAddr . output . MsgRoutedFrom) addr routeTo
  MsgRoutedFrom (RoutedFrom routedFromNode routedFromData) -> do
    recvdFrom routedFromNode routedFromData
    maybeNodeData <- stateLookupNode routedFromNode
    when (isNothing maybeNodeData) $ async_ do
      (recvFrom routedFromNode . closeToQueue . inputToQueue) do
        let r2NodeData = NodeData (R2 addr) routedFromNode
        runNodeHandler (sendTo routedFromNode . handleMsg self cmd r2NodeData) r2NodeData
  msg -> fail $ "unexpected message: " <> show msg

runNodeHandler ::
  ( Member (AtomicState (State s)) r,
    Members (TransportEffects Message Message) r,
    Member Resource r,
    Member Trace r,
    Show s,
    Eq s
  ) =>
  (Message -> Sem r ()) ->
  NodeData s ->
  Sem r ()
runNodeHandler f nodeData@(NodeData _ addr) =
  traceTagged ("r2nd " <> show addr) . stateReflectNode nodeData $
    handle @Message (raise @Trace . f)

runDefaultNodeHandler ::
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (TransportEffects Message Message) r,
    Member (RecvFrom Address Message) r,
    Member (SendTo Address Message) r,
    Member Async r,
    Member Resource r,
    Member Trace r,
    Member Fail r,
    Eq s,
    Show s
  ) =>
  Address ->
  String ->
  NodeData s ->
  Sem r ()
runDefaultNodeHandler self cmd nodeData = runNodeHandler (handleMsg self cmd nodeData) nodeData

r2cd ::
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Members (TransportEffects Message Message) r,
    Member (RecvFrom Address Message) r,
    Member (SendTo Address Message) r,
    Member Resource r,
    Member Trace r,
    Member Fail r,
    Eq s,
    Show s,
    Member Async r
  ) =>
  Address ->
  String ->
  NodeTransport s ->
  Sem r ()
r2cd self cmd transport = do
  addr <- exchangeSelves self Nothing
  let nodeData = NodeData transport addr
  runDefaultNodeHandler self cmd nodeData

r2d ::
  forall s r.
  ( Member (Accept s) r,
    Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Sockets Message Message s) r,
    Member (RecvFrom Address Message) r,
    Member Resource r,
    Member Async r,
    Member Trace r,
    Eq s,
    Show s
  ) =>
  Address ->
  String ->
  Sem r ()
r2d self cmd = foreverAcceptAsync \s -> socket s do
  result <- runFail . interpretSendToState $ r2cd self cmd (Sock s)
  trace $ show result
