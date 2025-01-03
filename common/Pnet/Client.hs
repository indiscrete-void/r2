module Pnet.Client (Command (..), listNodes, connectNode, pnet) where

import Control.Monad
import Data.ByteString (ByteString)
import Data.Maybe
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
import Polysemy.Wait
import System.Process.Extra
import Text.Printf qualified as Text

data Command
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Transport !(Maybe Address)

listNodes :: (Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r) => Sem r ()
listNodes = traceTagged "Ls" $ output ListNodes >> (inputOrFail @Response >>= trace . show)

streamIO :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r) => Sem r ()
streamIO = async_ nodeToIO >> ioToNode
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

streamIOWithEOF :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo (Maybe ByteString))) r, Member (Output (RoutedFrom (Maybe ByteString))) r, Member Trace r) => Sem r ()
streamIOWithEOF = async_ nodeToIO >> ioToNode
  where
    ioToNode = do
      i <- input
      output $ RoutedFrom defaultAddr i
      when (isJust i) ioToNode
    nodeToIO = handle $ r2Sem (const $ maybe close output . routedFromData) defaultAddr

runTransport :: (Members (TransportEffects ByteString ByteString) r, Member (Scoped CreateProcess Process) r) => Transport -> InterpretersFor (TransportEffects ByteString ByteString) r
runTransport Stdio = subsume_
runTransport (Process cmd) = execIO (ioShell cmd) . raise3Under @Wait

connectNode :: (Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r, Member Async r, Member (Output Handshake) r, Members (TransportEffects ByteString ByteString) r, Member Trace r, Member (Scoped CreateProcess Process) r) => Transport -> Maybe Address -> Sem r ()
connectNode transport maybeAddress = output (ConnectNode transport maybeAddress) >> runTransport transport streamIO

transportToR2 :: (Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r, Member ByteInputWithEOF r, Member (Output (RouteTo (Maybe ByteString))) r, Member ByteOutput r, Member (Scoped CreateProcess Process) r, Member Trace r, Member Async r, Member Close r) => Address -> Transport -> Sem r ()
transportToR2 address Stdio = ioToR2 address
transportToR2 address (Process cmd) = execIO (ioShell cmd) $ ioToR2 address

r2ProcToTransport :: (Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r, Member (Output (RouteTo Connection)) r, Member (Output Handshake) r, Member (Output (RouteTo (Maybe Handshake))) r, Members (TransportEffects ByteString ByteString) r, Member Trace r, Member Async r, Member (Scoped CreateProcess Process) r) => Address -> Transport -> Sem r ()
r2ProcToTransport address transport = do
  output Route
  connectR2 address
  runR2Output @Handshake address (output TunnelProcess)
  transportToR2 address transport

procToTransport :: (Member (Input (Maybe ByteString)) r, Member (Output Handshake) r, Member (Output ByteString) r, Member (Scoped CreateProcess Process) r, Member Trace r, Member Async r, Member Close r, Member (Input (Maybe (RouteTo (Maybe ByteString)))) r, Member (Output (RoutedFrom (Maybe ByteString))) r) => Transport -> Sem r ()
procToTransport transport = output TunnelProcess >> runTransport transport streamIOWithEOF

pnet ::
  ( Members (TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) r,
    Members (TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) r,
    Member (Output (RouteTo Connection)) r,
    Member (Output (RouteTo (Maybe Handshake))) r,
    Member (InputWithEOF Response) r,
    Member (Output Handshake) r,
    Member (InputWithEOF (RouteTo (Maybe ByteString))) r,
    Member (Output (RoutedFrom (Maybe ByteString))) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Self) r,
    Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Fail r,
    Member Trace r,
    Member Async r,
    Member (InputWithEOF Self) r
  ) =>
  Address ->
  Command ->
  Sem r ()
pnet me cmd = do
  output (Self me)
  server <- unSelf <$> inputOrFail @Self
  trace $ Text.printf "communicating with %s" (show server)
  go cmd
  where
    go Ls = listNodes
    go (Connect transport maybeAddress) = connectNode transport maybeAddress
    go (Tunnel transport Nothing) = procToTransport transport
    go (Tunnel transport (Just address)) = r2ProcToTransport address transport
