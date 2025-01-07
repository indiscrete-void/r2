module Pnet.Daemon where

import Control.Constraint
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.List qualified as List
import Pnet
import Pnet.Routing
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

stateAddNode :: (Member (AtomicState (State s)) r) => NodeData s -> Sem r ()
stateAddNode = atomicModify' . (:)

stateDeleteNode :: (Member (AtomicState (State s)) r, Eq s) => NodeData s -> Sem r ()
stateDeleteNode = atomicModify' . List.delete

stateLookupNode :: (Member (AtomicState (State s)) r) => Address -> Sem r (Maybe (NodeData s))
stateLookupNode addr = List.find ((== addr) . nodeDataAddr) <$> atomicGet

stateReflectNode :: (Show s, Eq s, Member (AtomicState (State s)) r, Member Trace r, Member Resource r) => NodeData s -> Sem r c -> Sem r c
stateReflectNode nodeData = bracket_ addNode delNode
  where
    addNode = trace (Text.printf "storing %s" $ show nodeData) >> stateAddNode nodeData
    delNode = trace (Text.printf "forgetting %s" $ show nodeData) >> stateDeleteNode nodeData

procToR2 ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    c (),
    c ByteString,
    Member Trace r,
    Member Async r
  ) =>
  String ->
  Address ->
  Sem r ()
procToR2 cmd = execIO (ioShell cmd) . ioToR2 @ByteString

tunnelProcess ::
  ( Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    c ByteString,
    c (),
    Member Trace r,
    Member Async r
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
    c ByteString
  ) =>
  Address ->
  String ->
  Address ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode self cmd router transport maybeNewNodeID = traceTagged "connection" do
  addr <- runR2 defaultAddr do
    outputAny (Self self)
    unSelf <$> inputAnyOrFail
  whenJust maybeNewNodeID \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (Text.printf "address mismatch")
  let nodeData = NodeData (Router transport router) addr
  stateReflectNode nodeData $
    trace . show @(Either String ())
      =<< runFail
        ( inputToAny @(RoutedFrom Connection)
            . runR2 defaultAddr
            $ forever
              ( acceptR2 >>= pnetnd self cmd . NodeData (Router transport addr)
              )
        )

runNodeOutput ::
  ( Member (AtomicState (State s)) r,
    Member (SocketsAny cs s) r,
    Member (OutputAny cs) r,
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
  let sendTo :: Address -> RoutedFrom Raw -> Sem r ()
      sendTo addr msg = do
        (Just nodeData) <- stateLookupNode addr
        runNodeOutput nodeData $ outputAny msg
  handle (r2Sem sendTo sender)

pnetnd ::
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
    c ByteString
  ) =>
  Address ->
  String ->
  NodeData s ->
  Sem r ()
pnetnd self cmd nodeData@(NodeData _ addr) =
  inputToAny @Handshake . traceTagged "pnetnd" . stateReflectNode nodeData $ handle \case
    (ConnectNode transport maybeNodeID) ->
      connectNode self cmd addr transport maybeNodeID
    ListNodes ->
      outputToAny @Response $ listNodes
    Route ->
      inputToAny @(RouteTo Raw) $ route addr
    TunnelProcess ->
      ioToAny @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) $ tunnelProcess cmd addr

pnetcd ::
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
    c ByteString,
    Member Async r
  ) =>
  Address ->
  String ->
  s ->
  Sem r ()
pnetcd self cmd s =
  outputAny (Self self)
    >> unSelf <$> inputAnyOrFail @Self
    >>= pnetnd self cmd . NodeData (Sock s)

pnetd ::
  forall c s r cs.
  ( Member (Accept s) r,
    Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (SocketsAny cs s) r,
    Member Resource r,
    Member Async r,
    Member Fail r,
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
    c ByteString
  ) =>
  Address ->
  String ->
  Sem r ()
pnetd self cmd = foreverAcceptAsync \s -> socketAny s $ pnetcd self cmd s
