module Pnet.Daemon where

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
import Polysemy.Sockets
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

procToR2 :: (Member (Scoped CreateProcess Process) r, Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r, Member (Output (RouteTo (Maybe ByteString))) r, Member Trace r, Member Async r) => String -> Address -> Sem r ()
procToR2 cmd = execIO (ioShell cmd) . ioToR2

tunnelProcess :: (Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r, Member (Scoped CreateProcess Process) r, Member (Output (RouteTo (Maybe ByteString))) r, Member Trace r, Member Async r) => String -> Address -> Sem r ()
tunnelProcess cmd addr = traceTagged ("tunnel " <> show addr) $ procToR2 cmd defaultAddr

listNodes :: (Member (AtomicState (State s)) r, Member (Output Response) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map nodeDataAddr <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (NodeList nodeList)

connectNode ::
  ( Member (AtomicState (State s)) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection)))) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString)))) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe Handshake))))) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Async r,
    Member Trace r,
    Eq s,
    Show s,
    Member (Output Response) r,
    Member (SocketsAny c s) r,
    c (RoutedFrom ByteString),
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    Member Resource r,
    Member Fail r,
    Member (InputWithEOF (RoutedFrom (Maybe Self))) r,
    Member (Output (RouteTo (Maybe Self))) r
  ) =>
  Address ->
  String ->
  Address ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode self cmd router transport maybeNewNodeID = traceTagged "connection" do
  addr <- runR2 @Self @Self defaultAddr do
    output (Self self)
    unSelf <$> inputOrFail
  whenJust maybeNewNodeID \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (Text.printf "address mismatch")
  let nodeData = NodeData (Router transport router) addr
  stateReflectNode nodeData $
    trace . show @(Either String ())
      =<< runFail
        ( runR2 @(RoutedFrom Connection) @(RouteTo Connection) defaultAddr
            . runR2 @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) defaultAddr
            . runR2 @(RoutedFrom (Maybe Handshake)) @(RouteTo (Maybe Handshake)) defaultAddr
            . runR2Input @(RouteTo ByteString) defaultAddr
            . runR2Input @Handshake defaultAddr
            . runR2Output @Handshake defaultAddr
            $ forever (acceptR2 >>= pnetnd self cmd . NodeData (Router transport addr))
        )

runNodeOutput ::
  forall c s o r.
  ( Member (AtomicState (State s)) r,
    Member (SocketsAny c s) r,
    Member Trace r,
    Member Fail r,
    Show o,
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    c o
  ) =>
  NodeData s ->
  InterpreterFor (Output o) r
runNodeOutput (NodeData transport addr) = case transport of
  Sock s -> socketAny s . outputToAny . insertAt @1 @(Any c)
  Router _ router -> \m -> do
    (Just routerData) <- stateLookupNode router
    runNodeOutput routerData
      . runR2Output @o addr
      . raiseUnder @(Output (RouteTo (Maybe o)))
      $ m

route ::
  forall c s r.
  ( Member (AtomicState (State s)) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (SocketsAny c s) r,
    c (RoutedFrom ByteString),
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    Member Trace r,
    Member Fail r
  ) =>
  Address ->
  Sem r ()
route sender = traceTagged "route" $ raise @Trace do
  trace ("routing for " ++ show sender)
  let sendTo :: Address -> RoutedFrom ByteString -> Sem r ()
      sendTo addr msg = do
        (Just nodeData) <- stateLookupNode addr
        runNodeOutput nodeData $ output msg
  handle (r2Sem sendTo sender)

pnetnd ::
  ( Member Trace r,
    Member (AtomicState (State s)) r,
    Member Fail r,
    Eq s,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom Connection)))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString)))) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Output (RouteTo (Maybe (RouteTo Connection)))) r,
    Member Close r,
    Member Async r,
    Member (Output Response) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r,
    Show s,
    Member (SocketsAny c s) r,
    c (RoutedFrom ByteString),
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    Member (InputWithEOF Handshake) r,
    Member (Output (RouteTo (Maybe ByteString))) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe Handshake))))) r,
    Member Resource r,
    Member (InputWithEOF (RoutedFrom (Maybe Self))) r,
    Member (Output (RouteTo (Maybe Self))) r
  ) =>
  Address ->
  String ->
  NodeData s ->
  Sem r ()
pnetnd self cmd nodeData@(NodeData _ addr) = traceTagged "pnetnd" . stateReflectNode nodeData $ handle go
  where
    go (ConnectNode transport maybeNodeID) = connectNode self cmd addr transport maybeNodeID
    go ListNodes = listNodes
    go Route = route addr
    go TunnelProcess = tunnelProcess cmd addr

pnetcd ::
  ( Member Trace r,
    Member (AtomicState (State s)) r,
    Member Fail r,
    Eq s,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom Connection)))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString)))) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe Handshake))))) r,
    Member (Output (RouteTo (Maybe (RouteTo Connection)))) r,
    Member Close r,
    Member Async r,
    Member (Output Response) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r,
    Member (Output (RouteTo (Maybe ByteString))) r,
    Member (InputWithEOF Self) r,
    Show s,
    Member (SocketsAny c s) r,
    c (RoutedFrom ByteString),
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    Member (InputWithEOF Handshake) r,
    Member (Output Self) r,
    Member Resource r,
    Member (InputWithEOF (RoutedFrom (Maybe Self))) r,
    Member (Output (RouteTo (Maybe Self))) r
  ) =>
  Address ->
  String ->
  s ->
  Sem r ()
pnetcd self cmd s = output (Self self) >> unSelf <$> inputOrFail @Self >>= pnetnd self cmd . NodeData (Sock s)

pnetd ::
  ( Member (Accept s) r,
    Member (Sockets Handshake Response s) r,
    Member (Sockets (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString)))) s) r,
    Member (Sockets (RouteTo (Maybe (RouteTo (Maybe ByteString)))) (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) s) r,
    Member (Sockets (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection))) s) r,
    Member (Sockets (RoutedFrom (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))))) (RouteTo (Maybe (RouteTo (Maybe (RouteTo (Maybe ByteString)))))) s) r,
    Member (Sockets (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))) (RouteTo (Maybe (RouteTo (Maybe Handshake)))) s) r,
    Member (Sockets (RoutedFrom (Maybe (RouteTo ByteString))) (RouteTo (Maybe (RoutedFrom ByteString))) s) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (Sockets (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString)) s) r,
    Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Trace r,
    Member Async r,
    Eq s,
    Member Fail r,
    Member (Sockets Self Self s) r,
    Member (Sockets (RoutedFrom Connection) (RouteTo Connection) s) r,
    Show s,
    Member (SocketsAny c s) r,
    c (RoutedFrom ByteString),
    forall ox. (c ox) => c (RouteTo ox),
    forall ox. (c ox) => c (Maybe ox),
    Member (Sockets (RoutedFrom (Maybe Handshake)) (RouteTo (Maybe Handshake)) s) r,
    Member Resource r,
    Member (Sockets (RoutedFrom (Maybe Self)) (RouteTo (Maybe Self)) s) r
  ) =>
  Address ->
  String ->
  Sem r ()
pnetd self cmd = foreverAcceptAsync \s ->
  socket @Handshake @Response s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) @(RouteTo (Maybe (RouteTo (Maybe ByteString)))) s
    . socket @(RouteTo (Maybe (RouteTo (Maybe ByteString)))) @(RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) s
    . socket @(RoutedFrom (Maybe (RoutedFrom Connection))) @(RouteTo (Maybe (RouteTo Connection))) s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))))) @(RouteTo (Maybe (RouteTo (Maybe (RouteTo (Maybe ByteString)))))) s
    . socket @(RouteTo ByteString) @(RoutedFrom ByteString) s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))) @(RouteTo (Maybe (RouteTo (Maybe Handshake)))) s
    . socket @(RoutedFrom (Maybe (RouteTo ByteString))) @(RouteTo (Maybe (RoutedFrom ByteString))) s
    . socket @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) s
    . socket @(RoutedFrom (Maybe Handshake)) @(RouteTo (Maybe Handshake)) s
    . socket @(RoutedFrom (Maybe Self)) @(RouteTo (Maybe Self)) s
    . socket @(RoutedFrom Connection) @(RouteTo Connection) s
    . socket @Self @Self s
    $ pnetcd self cmd s
