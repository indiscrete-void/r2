module R2.Peer.Client (Command (..), Action (..), listNodes, connectNode, r2c) where

import Control.Constraint
import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Wait
import R2
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

data Action
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Transport

data Command = Command
  { commandTargetChain :: [Address],
    commandAction :: Action
  }

listNodes ::
  ( Members (Any cs) r,
    cs Handshake,
    cs Response,
    Member Fail r,
    Member Trace r
  ) =>
  Sem r ()
listNodes = ioToAny $ traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)

streamIO ::
  ( Member Async r,
    Members (TransportEffects ByteString ByteString) r,
    Member (InputWithEOF (RouteTo Raw)) r,
    Member (Output (RoutedFrom Raw)) r,
    Member Trace r
  ) =>
  Sem r ()
streamIO = sequenceConcurrently_ [nodeToIO, ioToNode]
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

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

procToTransport ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Output ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Members (Any cs) r,
    cs Handshake,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    cs ByteString,
    cs Connection,
    Member Trace r,
    Member Async r
  ) =>
  Transport ->
  Sem r ()
procToTransport transport = outputAny TunnelProcess >> transportToR2 defaultAddr transport

runR2Session ::
  ( Members (Any cs) r,
    Member Trace r,
    cs Handshake,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    cs (RouteTo Connection),
    cs Connection
  ) =>
  Address ->
  InterpretersFor (Any cs) r
runR2Session target m = do
  outputAny Route
  outputToAny @(RouteTo Connection) $
    connectR2 target
  runR2 target m

runChainSession ::
  forall c cs r.
  ( Members (Any cs) r,
    Member Trace r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    cs ~ Show :&: c,
    cs (RouteTo Connection),
    cs Connection,
    cs Handshake
  ) =>
  [Address] ->
  InterpretersFor (Any cs) r
runChainSession [] m = subsume_ m
runChainSession (addr : rest) m =
  let mdup = insertAt @3 @(Any cs) m
   in runR2Session addr $ runChainSession rest mdup

handleAction ::
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
    cs Handshake,
    cs Connection,
    cs Response,
    cs ByteString
  ) =>
  Action ->
  Sem r ()
handleAction Ls = listNodes
handleAction (Connect transport maybeAddress) = connectNode transport maybeAddress
handleAction (Tunnel transport) = procToTransport transport

r2c ::
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
    cs Connection,
    cs Response,
    cs ByteString
  ) =>
  Address ->
  Command ->
  Sem r ()
r2c me (Command targetChain action) = do
  outputAny (Self me)
  server <- unSelf <$> inputToAny (inputOrFail @Self)
  trace $ Text.printf "communicating with %s" (show server)
  subsume_ @(Append (Any cs) r) @r $
    runChainSession targetChain $
      handleAction action
