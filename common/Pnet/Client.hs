module Pnet.Client (Command (..), listNodes, connectNode, pnet) where

import Data.ByteString (ByteString)
import Pnet
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
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

streamIO :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r) => Sem r ()
streamIO = async_ nodeToIO >> ioToNode
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

streamTransport :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r, Member (Scoped CreateProcess Process) r) => Transport -> Sem r ()
streamTransport Stdio = streamIO
streamTransport (Process cmd) = execIO (ioShell cmd) streamIO

connectNode :: (Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r, Member Async r, Member (Output Handshake) r, Members (TransportEffects ByteString ByteString) r, Member Trace r, Member (Scoped CreateProcess Process) r) => Transport -> Maybe Address -> Sem r ()
connectNode transport maybeAddress = output (ConnectNode transport maybeAddress) >> streamTransport transport

tunnelTransport :: (Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r, Member (Output (RouteTo Connection)) r, Member (Output Handshake) r, Member (Output (RouteTo (Maybe NodeHandshake))) r, Members (TransportEffects ByteString ByteString) r, Member Trace r, Member Async r) => Address -> Address -> Sem r ()
tunnelTransport self address =
  output (Route self)
    >> connectR2 address
    >> runR2Output @NodeHandshake address (output NodeTunnel)
    >> async_ (runR2Input @ByteString address inputToOutput)
    >> runR2Output @ByteString address inputToOutput
    >> runR2Close @ByteString address close

tunnel :: (Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r, Member ByteInputWithEOF r, Member (Output (RouteTo (Maybe ByteString))) r, Member (Output (RouteTo (Maybe NodeHandshake))) r, Member (Output (RouteTo Connection)) r, Member (Output Handshake) r, Member ByteOutput r, Member (Scoped CreateProcess Process) r, Member Trace r, Member Close r, Member Async r) => Address -> Address -> Transport -> Sem r ()
tunnel self address Stdio = tunnelTransport self address
tunnel self address (Process cmd) = execIO (ioShell cmd) $ tunnelTransport self address

pnet ::
  ( Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r,
    Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r,
    Member (Output (RouteTo Connection)) r,
    Member (Output (RouteTo (Maybe NodeHandshake))) r,
    Member (InputWithEOF Response) r,
    Member (Output Handshake) r,
    Member (Scoped CreateProcess Process) r,
    Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Command ->
  Sem r ()
pnet _ Ls = listNodes
pnet _ (Connect transport maybeAddress) = connectNode transport maybeAddress
pnet self (Tunnel address transport) = tunnel self address transport
