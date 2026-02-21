module R2.Daemon.Sockets (Sockets, bundleSocketEffects, socket, socketOutput) where

import Polysemy
import Polysemy.Bundle
import Polysemy.Scoped
import Polysemy.Transport

type Socket i o = Bundle (Transport i o)

bundleSocketEffects :: forall i o r. (Member (Socket i o) r) => InterpretersFor (Transport i o) r
bundleSocketEffects =
  sendBundle @(OutputWithEOF o) @(Transport i o)
    . sendBundle @(InputWithEOF i) @(Transport i o)

type Sockets i o s = Scoped s (Socket i o)

socket :: (Member (Sockets i o s) r) => s -> InterpretersFor (Transport i o) r
socket s = scoped s . bundleSocketEffects . raise2Under

socketOutput :: forall i o s r. (Member (Sockets i o s) r) => s -> InterpreterFor (OutputWithEOF o) r
socketOutput s = socket s . raise @(InputWithEOF i)
