module Pnet.Client (Command (..), pnet) where

import Control.Monad.Extra
import Data.ByteString (ByteString)
import Pnet
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport

data Command
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Address !Transport

pnet :: (Members (TransportEffects (RouteTo (Maybe ByteString)) (RoutedFrom (Maybe ByteString))) r, Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r, Member Close r, Member Async r) => Command -> Sem r ()
pnet Ls = traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)
pnet (Connect transport maybeAddress) = do
  output (ConnectNode transport maybeAddress)
  case transport of
    Stdio -> async_ nodeToIO >> ioToNode
      where
        ioToNode = whenJustM input (exposeR2 defaultAddr . output)
        nodeToIO = whenJustM (exposeR2 defaultAddr input) output
    _ -> _
pnet _ = _
