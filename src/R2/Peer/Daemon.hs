module R2.Peer.Daemon (State, initialState, ioToBus, tunnelProcess, r2d) where

import Control.Monad.Extra
import Data.List qualified as List
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Conc (Queue, QueueResult)
import Polysemy.Conc.Data.QueueResult qualified as QueueResult
import Polysemy.Conc.Effect.Queue qualified as Queue
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Opaque (Opaque)
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

-- node data
data NodeIdentity = Partial Address | Full Address
  deriving stock (Eq, Show)

data NodeData s = NodeData
  { nodeDataTransport :: NodeTransport s,
    nodeDataAddr :: Address
  }
  deriving stock (Eq, Show)

data NodeTransport s = Sock s | Pipe Transport Address | R2 Address
  deriving stock (Eq, Show)

-- state
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

-- i/o
ioToBus ::
  ( Member (RecvFrom Address i) r,
    Member (SendTo Address o) r
  ) =>
  Address ->
  InterpretersFor (TransportEffects i o) r
ioToBus addr = recvFrom addr . closeToQueue . sendTo addr . inputToQueue . raise3Under @(Queue _)

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
interpretSendToState = runScopedNew \addr m ->
  interpret
    ( \case
        Output o -> do
          (Just nodeData) <- stateLookupNode addr
          runNodeOutput nodeData $ output o
    )
    m

interceptRecvFromWrites ::
  forall r a.
  ( Member (RecvFrom Address Message) r
  ) =>
  (Address -> Message -> Sem r ()) ->
  Sem (RecvFrom Address Message ': r) a ->
  Sem (RecvFrom Address Message ': r) a
interceptRecvFromWrites f =
  raise_ . runScopedNew \addr m ->
    recvFrom addr $
      intercept @(Queue _)
        ( \case
            Queue.Read -> Queue.read
            Queue.TryRead -> Queue.tryRead
            Queue.ReadTimeout t -> Queue.readTimeout t
            Queue.Peek -> Queue.peek
            Queue.TryPeek -> Queue.tryPeek
            Queue.Write x -> do
              writeQueueResult addr (QueueResult.Success x)
              Queue.write x
            Queue.TryWrite x -> do
              result <- Queue.tryWrite x
              writeQueueResult addr (x <$ result)
              pure result
            Queue.WriteTimeout t x -> do
              result <- Queue.writeTimeout t x
              writeQueueResult addr (x <$ result)
              pure result
            Queue.Closed -> Queue.closed
            Queue.Close -> Queue.close
        )
        m
  where
    writeQueueResult :: Address -> QueueResult Message -> Sem (Queue Message ': Opaque q ': r) ()
    writeQueueResult addr (QueueResult.Success x) = raise_ $ f addr x
    writeQueueResult _ _ = pure ()

interceptRecvFromNewcomers ::
  ( Member (RecvFrom Address Message) r,
    Member (AtomicState (State s)) r
  ) =>
  Address ->
  (NodeData s -> Sem r ()) ->
  Sem (RecvFrom Address Message ': r) a ->
  Sem (RecvFrom Address Message ': r) a
interceptRecvFromNewcomers router f = interceptRecvFromWrites go
  where
    go addr _ =
      stateLookupNode addr >>= \case
        Nothing -> f $ NodeData (R2 router) addr
        Just _ -> pure ()

-- messages
tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (TransportEffects Message Message) r,
    Member Trace r,
    Member Async r
  ) =>
  String ->
  Sem r ()
tunnelProcess cmd = traceTagged "tunnel" $ execIO (ioShell cmd) ioToMsg

listNodes :: (Member (AtomicState (State s)) r, Member (Output Message) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map nodeDataAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (ResNodeList nodeList)

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
  r2nd self cmd $
    NodeData (Pipe transport router) addr

handleRouteTo :: (Member (SendTo Address Message) r) => Address -> RouteTo Message -> Sem r ()
handleRouteTo = r2 (\reqAddr -> sendTo reqAddr . output . MsgRoutedFrom)

handleRoutedFrom :: (Member (RecvFrom Address i) r) => RoutedFrom i -> Sem r ()
handleRoutedFrom (RoutedFrom routedFromNode routedFromData) = recvdFrom routedFromNode routedFromData

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
  ReqTunnelProcess -> tunnelProcess cmd
  MsgRouteTo routeTo -> handleRouteTo addr routeTo
  MsgRoutedFrom routedFrom -> handleRoutedFrom routedFrom
  msg -> fail $ "unexpected message: " <> show msg

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

-- networking
r2nbd ::
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
  Sem r ()
r2nbd self cmd nodeData@(NodeData _ addr) = ioToBus addr $ r2nd self cmd nodeData

r2nd ::
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
r2nd self cmd nodeData@(NodeData _ addr) =
  traceTagged ("r2nd " <> show addr) . stateReflectNode nodeData . subsume $
    interceptRecvFromNewcomers addr (async_ . r2nbd self cmd) $
      handle (handleMsg self cmd nodeData)

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
  result <- runFail . interpretSendToState $ do
    addr <- exchangeSelves self Nothing
    r2nd self cmd $ NodeData (Sock s) addr
  trace $ show result
