module Pnet.Daemon (pnetd) where

import Data.ByteString (ByteString)
import Pnet
import Pnet.Daemon.Server
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Socket.Accept
import Polysemy.Sockets
import Polysemy.Trace

pnetd :: (Member (Accept s) r, Member (Sockets Handshake Response s) r, Member (Sockets (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString)))) s) r, Member (AtomicState (State s)) r, Member Trace r, Member Async r, Eq s) => Sem r ()
pnetd = foreverAcceptAsync \s ->
  socket @Handshake @Response s
    . socket @(RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) @(RouteTo (Maybe (RouteTo (Maybe ByteString)))) s
    $ pnetcd s
