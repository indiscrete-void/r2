module Pnet.Client (Command (..), listNodes, connectNode, pnet) where

import Data.ByteString (ByteString)
import Pnet
import Pnet.Routing
import Pnet.Routing.Transfer
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import System.Process.Extra

data Command
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Address !Transport

listNodes :: (Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r) => Sem r ()
listNodes = traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)

connectNode :: (Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r, Member Async r, Member (Output Handshake) r, Members (TransportEffects ByteString ByteString) r, Member Trace r, Member (Scoped CreateProcess Process) r) => Transport -> Maybe Address -> Sem r ()
connectNode transport maybeAddress = output (ConnectNode transport maybeAddress) >> streamTransport transport

pnet ::
  ( Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r,
    Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member (Scoped CreateProcess Process) r,
    Member (InputWithEOF Response) r,
    Member (Output Handshake) r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Command ->
  Sem r ()
pnet Ls = listNodes
pnet (Connect transport maybeAddress) = connectNode transport maybeAddress
pnet (Tunnel _ _) = _
