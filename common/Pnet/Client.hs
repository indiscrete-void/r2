module Pnet.Client (Command (..), listNodes, connectNode, pnet) where

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

streamIO :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r) => Sem r ()
streamIO = async_ nodeToIO >> ioToNode
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

streamTransport :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r) => Transport -> Sem r ()
streamTransport Stdio = streamIO
streamTransport (Process _) = _

listNodes :: (Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r) => Sem r ()
listNodes = traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)

connectNode :: (Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r, Member Async r, Member (Output Handshake) r, Members (TransportEffects ByteString ByteString) r, Member Trace r) => Transport -> Maybe Address -> Sem r ()
connectNode transport maybeAddress = output (ConnectNode transport maybeAddress) >> streamTransport transport

pnet ::
  ( Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r,
    Member ByteInputWithEOF r,
    Member ByteOutput r,
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
