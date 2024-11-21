module Pnet.Daemon.Server (listNodes, connectNode, pnetcd) where

import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.Maybe
import Pnet
import Pnet.Daemon.Node
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Sockets
import Polysemy.Trace
import Polysemy.Transport
import System.Process.Extra
import Text.Printf qualified as Text

listNodes :: (Member (AtomicState (State s)) r, Member (Output Response) r, Member Trace r) => Sem r ()
listNodes = traceTagged "ListNodes" do
  nodeList <- map snd <$> atomicGet
  trace (Text.printf "responding with `%s`" (show nodeList))
  output (NodeList nodeList)

connectNode ::
  ( Member (AtomicState (State s)) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection)))) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (Input (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))))) r,
    Member (Input (Maybe (RoutedFrom (Maybe (RouteTo ByteString))))) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe Handshake))))) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Async r,
    Member Trace r,
    Eq s
  ) =>
  String ->
  s ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode cmd s transport maybeNodeID = traceTagged "connection" do
  let nodeID = fromJust maybeNodeID
  trace (Text.printf "%s connected over `%s`" nodeIDStr (show transport))
  whenJust maybeNodeID (stateAddNode . entry)
  traceTagged "pnetnd" . trace . show @(Either String ())
    =<< runFail
      ( runR2 @(RoutedFrom Connection) @(RouteTo Connection) defaultAddr
          . runR2 @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) defaultAddr
          . runR2 @(RoutedFrom (Maybe Handshake)) @(RouteTo (Maybe Handshake)) defaultAddr
          . runR2Input @(RouteTo ByteString) defaultAddr
          $ forever (acceptR2 >>= pnetnd cmd nodeID)
      )
  trace (Text.printf "%s disconnected from `%s`" nodeIDStr (show transport))
  whenJust maybeNodeID (stateDeleteNode . entry)
  where
    nodeIDStr = maybe "unknown node" show maybeNodeID
    entry nodeID = (s, nodeID)

routeClient :: (Eq s, Member (InputWithEOF (RouteTo ByteString)) r, Member (AtomicState (State s)) r, Member (Sockets i (RouteTo (Maybe (RoutedFrom ByteString))) s) r, Member Trace r) => s -> Address -> Sem r ()
routeClient s sender =
  let runClientOutput c =
        socketOutput c
          . runR2Output defaultAddr
          . raiseUnder @(Output (RouteTo (Maybe (RoutedFrom ByteString))))
      entry = (s, sender)
   in stateAddNode entry >> route runClientOutput sender >> stateDeleteNode entry

pnetcd ::
  ( Members (TransportEffects Handshake Response) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection)))) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Sockets (RoutedFrom (Maybe (RouteTo ByteString))) (RouteTo (Maybe (RoutedFrom ByteString))) s) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString)))) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe Handshake))))) r,
    Member (AtomicState (State s)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Async r,
    Member Trace r,
    Eq s
  ) =>
  String ->
  s ->
  Sem r ()
pnetcd cmd s = handle \case
  ListNodes -> listNodes
  (ConnectNode transport maybeNodeID) -> connectNode cmd s transport maybeNodeID
  Route (Just sender) -> routeClient s sender
  _ -> _
