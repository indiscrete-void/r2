module Polysemy.Sockets (Sockets, bundleSocketEffects, socket, socketOutput) where

import Polysemy
import Polysemy.Bundle
import Polysemy.Scoped
import Polysemy.Transport

type Socket i o = Bundle (TransportEffects i o)

bundleSocketEffects :: forall i o r. (Member (Socket i o) r) => InterpretersFor (TransportEffects i o) r
bundleSocketEffects =
  sendBundle @Close @(TransportEffects i o)
    . sendBundle @(Output o) @(TransportEffects i o)
    . sendBundle @(InputWithEOF i) @(TransportEffects i o)

type Sockets i o s = Scoped s (Socket i o)

socket :: (Member (Sockets i o s) r) => s -> InterpretersFor (TransportEffects i o) r
socket s = scoped s . bundleSocketEffects . raise3Under

socketOutput :: forall i o s r. (Member (Sockets i o s) r) => s -> InterpreterFor (Output o) r
socketOutput s = socket s . raise @(InputWithEOF i) . raiseUnder @Close
