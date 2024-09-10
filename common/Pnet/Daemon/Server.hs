module Pnet.Daemon.Server (State, initialState, pnetcd) where

import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.List qualified as List
import Pnet
import Pnet.Daemon.Node
import Pnet.Routing
import Polysemy
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import Text.Printf qualified as Text

type State s = [(s, Address)]

initialState :: State s
initialState = []

pnetcd :: (Members (TransportEffects Handshake Response) r, Members (TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) r, Member (AtomicState (State s)) r, Member Trace r, Eq s) => s -> Sem r ()
pnetcd = handle . go
  where
    go _ ListNodes = do
      nodeList <- map snd <$> atomicGet
      traceTagged "ListNodes" (Text.printf "responding with `%s`" (show nodeList))
      output (NodeList nodeList)
    go s (ConnectNode transport maybeNodeID) = do
      traceTagged "NodeAvailability" (Text.printf "%s connected over `%s`" nodeIDStr (show transport))
      whenJust maybeNodeID (atomicModify' . (:) . entry)
      traceTagged "pnetnd" . show =<< runFail (runR2 defaultAddr pnetnd)
      traceTagged "NodeAvailability" (Text.printf "%s disconnected from `%s`" nodeIDStr (show transport))
      whenJust maybeNodeID (atomicModify' . List.delete . entry)
      where
        nodeIDStr = maybe "unknown node" show maybeNodeID
        entry nodeID = (s, nodeID)
