module R2.Peer.Daemon (State, initialState, r2d) where

import Control.Constraint
import Control.Monad.Extra
import Data.List qualified as List
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.Socket.Accept
import Polysemy.Sockets.Any
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

data NodeTransport s = Sock s | Router Transport Address
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
    Member (SocketsAny cs s) r,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw),
    Member Trace r,
    Member Fail r,
    cs ~ Show :&: c
  ) =>
  NodeData s ->
  InterpreterFor (OutputAny cs) r
runNodeOutput (NodeData transport addr) = case transport of
  Sock s -> socketAny s . raise @(InputAnyWithEOF _) . raiseUnder @Close
  Router _ router -> \m -> do
    (Just routerData) <- stateLookupNode router
    runNodeOutput routerData
      . runR2Output addr
      . raiseUnder @(OutputAny _)
      $ m

interpretSendToState ::
  ( Member (SocketsAny cs s) r,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw),
    Member (AtomicState (State s)) r,
    cs ~ Show :&: c,
    Member Fail r,
    Member Trace r,
    cs o
  ) =>
  InterpreterFor (SendTo Address o) r
interpretSendToState = runScopedNew \addr m -> do
  (Just nodeData) <- stateLookupNode addr
  runNodeOutput nodeData . outputToAny . raiseUnder @(OutputAny _) $ m

procToR2 ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    c (),
    c Raw,
    Member Trace r,
    Member Async r,
    Member Fail r
  ) =>
  String ->
  Address ->
  Sem r ()
procToR2 cmd = execIO (ioShell cmd) . outputBsToRaw . inputBsToRaw . ioToR2 @Raw

tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    c Raw,
    c (),
    Member Trace r,
    Member Async r,
    Member Fail r
  ) =>
  String ->
  Address ->
  Sem r ()
tunnelProcess cmd addr = traceTagged ("tunnel " <> show addr) $ procToR2 cmd defaultAddr

listNodes :: (Member (AtomicState (State s)) r, Member (Output Response) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map nodeDataAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (NodeList nodeList)

exchangeSelves ::
  ( Member (InputAny Maybe c) r,
    Member (OutputAny c) r,
    c Self,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  Sem r Address
exchangeSelves self maybeKnownAddr = do
  outputAny (Self self)
  addr <- unSelf <$> inputAnyOrFail
  whenJust maybeKnownAddr \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (Text.printf "address mismatch")
  pure addr

connectNode ::
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (SocketsAny cs s) r,
    Members (Any cs) r,
    Member Async r,
    Member Resource r,
    Member Fail r,
    Member Trace r,
    Eq s,
    Show s,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs Self,
    cs (RoutedFrom Connection),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw),
    cs Handshake,
    cs Response,
    c (),
    c Raw,
    c (RouteTo Connection)
  ) =>
  Address ->
  String ->
  Address ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode self cmd router transport maybeNewNodeID = do
  addr <- runR2 defaultAddr $ exchangeSelves self maybeNewNodeID
  traceTagged ("connection " <> show addr) do
    let nodeData = NodeData (Router transport router) addr
    stateReflectNode nodeData $
      trace . show @(Either String ())
        =<< runFail
          ( runR2 defaultAddr
              . outputToAny @(RouteTo Connection)
              . inputToAny @(RoutedFrom Connection)
              $ forever
                ( acceptR2 >>= go addr
                )
          )
  where
    runR2OutputSession addr m = bracket_ (connectR2 self) (runR2Close self close) do
      runR2Output self $ do
        outputAny Route
        runR2Output addr m
    runOutputSession _ Route = subsume_
    runOutputSession (NodeData _ addr) _ = runR2OutputSession addr
    handleHandshakeR2 nodeData handshake = runOutputSession nodeData handshake $ handleHandshake self cmd nodeData handshake
    go parent addr =
      let nodeData = NodeData (Router transport parent) addr
       in runR2Input addr $ runNodeHandler (handleHandshakeR2 nodeData) nodeData

route ::
  forall c s r cs.
  ( Member (AtomicState (State s)) r,
    Member (InputWithEOF (RouteTo Raw)) r,
    Member (SocketsAny cs s) r,
    Member (OutputAny cs) r,
    Member Trace r,
    Member Fail r,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw)
  ) =>
  Address ->
  Sem r ()
route sender = traceTagged "route" $ raise @Trace do
  trace ("routing for " ++ show sender)
  let sendTo :: (cs a) => Address -> a -> Sem r ()
      sendTo addr msg = do
        (Just nodeData) <- stateLookupNode addr
        runNodeOutput nodeData $ outputAny msg
  handle (r2Sem sendTo sender)

handleHandshake ::
  forall c s r cs.
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (SocketsAny cs s) r,
    Members (Any cs) r,
    Member Resource r,
    Member Fail r,
    Member Async r,
    Member Trace r,
    Show s,
    Eq s,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw),
    cs Handshake,
    cs Response,
    cs Self,
    cs (RoutedFrom Connection),
    c (),
    c (RouteTo Connection),
    c Raw
  ) =>
  Address ->
  String ->
  NodeData s ->
  Handshake ->
  Sem r ()
handleHandshake self cmd (NodeData _ addr) = \case
  (ConnectNode transport maybeNodeID) ->
    connectNode self cmd addr transport maybeNodeID
  ListNodes ->
    outputToAny @Response $ listNodes
  Route ->
    inputToAny @(RouteTo Raw) $ route addr
  TunnelProcess ->
    ioToAny @(RoutedFrom (Maybe Raw)) @(RouteTo (Maybe Raw)) $ tunnelProcess cmd addr

runNodeHandler ::
  forall c s r cs.
  ( Member (AtomicState (State s)) r,
    Members (Any cs) r,
    Member Resource r,
    Member Trace r,
    Show s,
    Eq s,
    cs ~ Show :&: c,
    cs Handshake,
    Member Fail r
  ) =>
  (Handshake -> Sem r ()) ->
  NodeData s ->
  Sem r ()
runNodeHandler f nodeData@(NodeData _ addr) =
  traceTagged ("r2nd " <> show addr) . inputToAny @Handshake . stateReflectNode nodeData $
    inputOrFail @Handshake >>= raise @(InputWithEOF Handshake) . raise @Trace . f

r2cd ::
  forall c s r cs.
  ( Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (SocketsAny cs s) r,
    Members (Any cs) r,
    Member Resource r,
    Member Trace r,
    Member Fail r,
    Eq s,
    Show s,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    cs (RoutedFrom Connection),
    cs (RoutedFrom Raw),
    cs (RouteTo Raw),
    cs Handshake,
    cs Response,
    cs Self,
    c (),
    Member Async r,
    c (RouteTo Connection),
    c Raw
  ) =>
  Address ->
  String ->
  NodeTransport s ->
  Sem r ()
r2cd self cmd transport = do
  addr <- exchangeSelves self Nothing
  let nodeData = NodeData transport addr
  runNodeHandler (handleHandshake self cmd nodeData) nodeData

r2nd self cmd transport =
  acceptR2 >>= \addr ->
    runR2 addr $ r2cd self cmd transport

r2d ::
  forall c cs s r.
  ( Member (Accept s) r,
    Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (SocketsAny cs s) r,
    Member Resource r,
    Member Async r,
    Member Trace r,
    Eq s,
    Show s,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    cs (RoutedFrom Connection),
    cs (RouteTo Raw),
    cs (RoutedFrom Raw),
    cs Handshake,
    cs Response,
    cs Self,
    c (),
    c (RouteTo Connection),
    c Raw
  ) =>
  Address ->
  String ->
  Sem r ()
r2d self cmd = foreverAcceptAsync \s -> socketAny s do
  result <- runFail $ r2cd self cmd (Sock s)
  trace $ show result
