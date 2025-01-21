module Pnet.Client (Command (..), listNodes, connectNode, pnet) where

import Control.Constraint
import Control.Monad
import Data.ByteString (ByteString)
import Data.Maybe
import Pnet
import Pnet.Routing
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Wait
import System.Process.Extra
import Text.Printf qualified as Text

data Command
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Transport !(Maybe Address)

listNodes :: (Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r) => Sem r ()
listNodes = traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)

streamIO ::
  ( Member Async r,
    Members (TransportEffects ByteString ByteString) r,
    Member (InputWithEOF (RouteTo Raw)) r,
    Member (Output (RoutedFrom Raw)) r,
    Member Trace r
  ) =>
  Sem r ()
streamIO = async_ nodeToIO >> ioToNode
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

streamIOWithEOF ::
  ( Member Async r,
    Members (TransportEffects ByteString ByteString) r,
    Member (InputWithEOF (RouteTo (Maybe ByteString))) r,
    Member (Output (RoutedFrom (Maybe ByteString))) r,
    Member Trace r
  ) =>
  Sem r ()
streamIOWithEOF = async_ nodeToIO >> ioToNode
  where
    ioToNode = do
      i <- input
      output $ RoutedFrom defaultAddr i
      when (isJust i) ioToNode
    nodeToIO = handle $ r2Sem (const $ maybe close output . routedFromData) defaultAddr

runTransport ::
  ( Members (TransportEffects ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r
  ) =>
  Transport ->
  InterpretersFor (TransportEffects ByteString ByteString) r
runTransport Stdio = subsume_
runTransport (Process cmd) = execIO (ioShell cmd) . raise3Under @Wait

connectNode ::
  ( Member Async r,
    Members (Any cs) r,
    cs Handshake,
    cs (RouteTo Raw),
    cs (RoutedFrom Raw),
    Members (TransportEffects ByteString ByteString) r,
    Member Trace r,
    Member (Scoped CreateProcess Process) r
  ) =>
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode transport maybeAddress =
  outputAny (ConnectNode transport maybeAddress)
    >> runTransport transport (ioToAny @(RouteTo Raw) @(RoutedFrom Raw) $ streamIO)

transportToR2 ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Close r,
    Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    c (),
    c ByteString,
    cs ~ Show :&: c,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Transport ->
  Sem r ()
transportToR2 address Stdio = ioToR2 @ByteString address
transportToR2 address (Process cmd) = execIO (ioShell cmd) $ ioToR2 address

r2ProcToTransport ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Close r,
    Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs Handshake,
    cs (RouteTo Connection),
    c (),
    c ByteString,
    cs ~ Show :&: c,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Transport ->
  Sem r ()
r2ProcToTransport address transport = do
  outputAny Route
  outputToAny @(RouteTo Connection) $ connectR2 address
  runR2Input address . runR2Output address $ do
    outputAny TunnelProcess
    transportToR2 defaultAddr transport

procToTransport ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Output ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    cs Handshake,
    cs (RouteTo (Maybe ByteString)),
    cs (RoutedFrom (Maybe ByteString)),
    Member Trace r,
    Member Async r
  ) =>
  Transport ->
  Sem r ()
procToTransport transport =
  outputAny TunnelProcess
    >> runTransport transport (ioToAny @(RouteTo (Maybe ByteString)) @(RoutedFrom (Maybe ByteString)) streamIOWithEOF)

pnet ::
  forall c cs r.
  ( Members (Any cs) r,
    Members (TransportEffects ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Trace r,
    Member Async r,
    cs ~ Show :&: c,
    forall msg. (cs msg) => cs (RoutedFrom msg),
    forall msg. (cs msg) => cs (RouteTo msg),
    forall msg. (cs msg) => cs (Maybe msg),
    cs (RouteTo Raw),
    cs (RoutedFrom Raw),
    cs Self,
    cs Handshake,
    cs (RouteTo Connection),
    c (),
    cs Response,
    cs ByteString,
    cs (Maybe ByteString)
  ) =>
  Address ->
  Command ->
  Sem r ()
pnet me cmd = do
  outputAny (Self me)
  server <- unSelf <$> inputToAny (inputOrFail @Self)
  trace $ Text.printf "communicating with %s" (show server)
  case cmd of
    Ls -> ioToAny listNodes
    (Connect transport maybeAddress) -> connectNode transport maybeAddress
    (Tunnel transport Nothing) -> procToTransport transport
    (Tunnel transport (Just address)) -> r2ProcToTransport address transport
