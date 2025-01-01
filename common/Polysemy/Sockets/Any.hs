module Polysemy.Sockets.Any (SocketAny, bundleSocketAnyEffects, SocketsAny, socketAny, socketOutputAny) where

import Polysemy
import Polysemy.Any
import Polysemy.Bundle
import Polysemy.Scoped
import Polysemy.Transport

type SocketAny c = Bundle (Any c)

bundleSocketAnyEffects :: forall c r. (Member (SocketAny c) r) => InterpretersFor (Any c) r
bundleSocketAnyEffects =
  sendBundle @Close @(Any c)
    . sendBundle @(OutputAny c) @(Any c)
    . sendBundle @(InputAny c) @(Any c)

type SocketsAny c s = Scoped s (SocketAny c)

socketAny :: (Member (SocketsAny c s) r) => s -> InterpretersFor (Any c) r
socketAny s = scoped s . bundleSocketAnyEffects . raise3Under

socketOutputAny :: forall c s r. (Member (SocketsAny c s) r) => s -> InterpreterFor (OutputAny c) r
socketOutputAny s = socketAny s . raise @(InputAny c) . raiseUnder @Close
