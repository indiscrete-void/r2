module Pnet.Daemon.Server (listNodes, connectNode, pnetcd) where

import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.Maybe
import Pnet
import Pnet.Daemon.Node
import Pnet.Routing
import Polysemy
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Sockets
import Polysemy.Trace
import Polysemy.Transport
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
    Member (Input (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe NodeHandshake)))))) r,
    Member (Input (Maybe (RoutedFrom (Maybe (RouteTo ByteString))))) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe NodeHandshake))))) r,
    Member Trace r,
    Eq s
  ) =>
  s ->
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode s transport maybeNodeID = traceTagged "connection" do
  let nodeID = fromJust maybeNodeID
  trace (Text.printf "%s connected over `%s`" nodeIDStr (show transport))
  whenJust maybeNodeID (stateAddNode . entry)
  traceTagged "pnetnd" . trace . show @(Either String ())
    =<< runFail
      ( runR2 @(RoutedFrom Connection) @(RouteTo Connection) defaultAddr
          . runR2 @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) defaultAddr
          . runR2 @(RoutedFrom (Maybe NodeHandshake)) @(RouteTo (Maybe NodeHandshake)) defaultAddr
          . runR2Input @(RouteTo ByteString) defaultAddr
          . runR2Input @(RoutedFrom (Maybe NodeHandshake)) defaultAddr
          $ forever (acceptR2 >>= pnetnd nodeID)
      )
  trace (Text.printf "%s disconnected from `%s`" nodeIDStr (show transport))
  whenJust maybeNodeID (stateDeleteNode . entry)
  where
    nodeIDStr = maybe "unknown node" show maybeNodeID
    entry nodeID = (s, nodeID)

pnetcd ::
  ( Members (TransportEffects Handshake Response) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection)))) r,
    Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r,
    Member (Sockets (RoutedFrom (Maybe (RouteTo ByteString))) (RouteTo (Maybe (RoutedFrom ByteString))) s) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe NodeHandshake))))) r,
    Member (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString)))) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (Output (RouteTo (Maybe (RouteTo (Maybe NodeHandshake))))) r,
    Member (AtomicState (State s)) r,
    Member Trace r,
    Eq s
  ) =>
  s ->
  Sem r ()
pnetcd s = handle \case
  ListNodes -> listNodes
  (ConnectNode transport maybeNodeID) -> connectNode s transport maybeNodeID
  Route sender ->
    let entry = (s, sender)
     in stateAddNode entry >> route runClientOutput sender >> stateDeleteNode entry
  where
    runClientOutput s = socketOutput s . runR2Output defaultAddr . raiseUnder @(Output (RouteTo (Maybe (RoutedFrom ByteString))))
