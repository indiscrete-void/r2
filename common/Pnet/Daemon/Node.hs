module Pnet.Daemon.Node (State, initialState, stateAddNode, stateDeleteNode, route, tunnelProcess, pnetnd) where

import Data.ByteString
import Data.List qualified as List
import Data.Maybe
import Pnet
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Sockets
import Polysemy.Trace
import Polysemy.Transport
import System.Process.Extra

type State s = [(s, Address)]

initialState :: State s
initialState = []

stateAddNode :: (Member (AtomicState (State s)) r) => (s, Address) -> Sem r ()
stateAddNode = atomicModify' . (:)

stateDeleteNode :: (Member (AtomicState (State s)) r, Eq s) => (s, Address) -> Sem r ()
stateDeleteNode = atomicModify' . List.delete

runAddress :: (Member (AtomicState (State s)) r) => (s -> InterpreterFor (Output o) r) -> Address -> InterpreterFor (Output o) r
runAddress f addr m = do
  s <- lookupSocket <$> atomicGet
  f s m
  where
    lookupSocket = fst . fromJust . List.find ((== addr) . snd)

route ::
  forall s r.
  ( Member (AtomicState (State s)) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member Trace r
  ) =>
  (s -> InterpreterFor (Output (RoutedFrom ByteString)) r) ->
  Address ->
  Sem r ()
route f sender = traceTagged "route" $ raise @Trace do
  trace ("routing for " ++ show sender)
  let sendTo :: Address -> RoutedFrom ByteString -> Sem r ()
      sendTo addr = runAddress f addr . output
  handle (r2Sem sendTo sender)

tunnelProcess :: (Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r, Member Trace r, Member (Output (RouteTo (Maybe NodeHandshake))) r, Member (Output (RouteTo Connection)) r, Member (Scoped CreateProcess Process) r, Member Async r) => Address -> String -> Sem r ()
tunnelProcess addr cmd = traceTagged ("tunnel " <> show addr) do
  trace ("tunneling for " ++ show addr)
  connectR2 addr
  runR2Output addr $ output NodeRoute
  execIO (ioShell cmd) $ ioToR2 addr

pnetnd ::
  ( Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r,
    Member (Sockets (RouteTo ByteString) (RoutedFrom ByteString) s) r,
    Member (InputWithEOF (RoutedFrom (Maybe NodeHandshake))) r,
    Member (InputWithEOF (RouteTo ByteString)) r,
    Member (Output (RouteTo (Maybe NodeHandshake))) r,
    Member (AtomicState (State s)) r,
    Member Fail r,
    Member Trace r,
    Member (Output (RouteTo Connection)) r,
    Member (Scoped CreateProcess Process) r,
    Member Async r
  ) =>
  String ->
  Address ->
  Address ->
  Sem r ()
pnetnd cmd peer addr = traceTagged "pnetnd" $ raise @Trace do
  trace ("accepted " <> show addr)
  handshake <- runR2Input @NodeHandshake addr $ inputOrFail @NodeHandshake
  case handshake of
    NodeRoute -> route socketOutput peer
    NodeTunnel -> tunnelProcess addr cmd
