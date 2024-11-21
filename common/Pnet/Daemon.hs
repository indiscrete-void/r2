module Pnet.Daemon (pnetd) where

import Data.ByteString (ByteString)
import Pnet
import Pnet.Daemon.Node
import Pnet.Daemon.Server
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Socket.Accept
import Polysemy.Sockets
import Polysemy.Trace
import System.Process.Extra

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
    Eq s
  ) =>
  String ->
  Sem r ()
pnetd cmd = foreverAcceptAsync \s ->
  socket @Handshake @Response s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) @(RouteTo (Maybe (RouteTo (Maybe ByteString)))) s
    . socket @(RouteTo (Maybe (RouteTo (Maybe ByteString)))) @(RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) s
    . socket @(RoutedFrom (Maybe (RoutedFrom Connection))) @(RouteTo (Maybe (RouteTo Connection))) s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))))) @(RouteTo (Maybe (RouteTo (Maybe (RouteTo (Maybe ByteString)))))) s
    . socket @(RouteTo ByteString) @(RoutedFrom ByteString) s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))) @(RouteTo (Maybe (RouteTo (Maybe Handshake)))) s
    . socket @(RoutedFrom (Maybe (RouteTo ByteString))) @(RouteTo (Maybe (RoutedFrom ByteString))) s
    . socket @(RoutedFrom (Maybe ByteString)) @(RouteTo (Maybe ByteString)) s
    $ pnetcd cmd s
