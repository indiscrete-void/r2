module Polysemy.Sockets (Sockets, bundleSockEffects, socket) where

import Polysemy
import Polysemy.Bundle
import Polysemy.Scoped
import Polysemy.Socket
import Polysemy.Transport

type Socket i o = Bundle (SocketEffects i o)

bundleSockEffects :: forall i o r. (Member (Socket i o) r) => InterpretersFor (SocketEffects i o) r
bundleSockEffects =
  sendBundle @Close @(SocketEffects i o)
    . sendBundle @(Output o) @(SocketEffects i o)
    . sendBundle @(InputWithEOF i) @(SocketEffects i o)

type Sockets i o s = Scoped s (Socket i o)

socket :: (Member (Sockets i o s) r) => s -> InterpretersFor (SocketEffects i o) r
socket s = scoped s . bundleSockEffects . raise3Under
