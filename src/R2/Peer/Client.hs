module R2.Peer.Client (Command (..), Action (..), listNodes, connectNode, r2c) where

import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Extra
import Polysemy.Wait
import R2
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

data Action
  = Ls
  | Connect !Transport !(Maybe Address)
  | Tunnel !Transport

data Command = Command
  { commandTargetChain :: [Address],
    commandAction :: Action
  }

listNodes ::
  ( Members (TransportEffects Message Message) r,
    Member Fail r,
    Member Trace r
  ) =>
  Sem r ()
listNodes = traceTagged "Ls" $ output ReqListNodes >> (inputOrFail @Message >>= trace . show)

connectTransport ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Close r,
    Member (Scoped CreateProcess Process) r,
    Members (TransportEffects Message Message) r,
    Member Trace r,
    Member Async r,
    Member Fail r
  ) =>
  Transport ->
  Sem r ()
connectTransport Stdio = ioToMsg
connectTransport (Process cmd) = execIO (ioShell cmd) ioToMsg

connectNode ::
  ( Member Async r,
    Members (TransportEffects Message Message) r,
    Members (TransportEffects ByteString ByteString) r,
    Member Trace r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r
  ) =>
  Transport ->
  Maybe Address ->
  Sem r ()
connectNode transport maybeAddress = output (ReqConnectNode transport maybeAddress) >> connectTransport transport

procToTransport ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Output ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Members (TransportEffects Message Message) r,
    Member Trace r,
    Member Async r,
    Member Fail r
  ) =>
  Transport ->
  Sem r ()
procToTransport transport = output ReqTunnelProcess >> connectTransport transport

runChainSession ::
  ( Members (TransportEffects Message Message) r,
    Member Trace r,
    Member Fail r
  ) =>
  [Address] ->
  InterpretersFor (TransportEffects Message Message) r
runChainSession [] m = subsume_ m
runChainSession (addr : rest) m =
  let mdup = insertAt @3 @(TransportEffects Message Message) m
   in runR2 addr $ runChainSession rest mdup

handleAction ::
  ( Members (TransportEffects Message Message) r,
    Members (TransportEffects ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Action ->
  Sem r ()
handleAction Ls = listNodes
handleAction (Connect transport maybeAddress) = connectNode transport maybeAddress
handleAction (Tunnel transport) = procToTransport transport

r2c ::
  ( Members (TransportEffects Message Message) r,
    Members (TransportEffects ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Command ->
  Sem r ()
r2c me (Command targetChain action) = do
  output (MsgSelf $ Self me)
  (Just server) <- fmap unSelf <$> contramapInput (>>= msgSelf) (input @(Maybe Self))
  trace $ Text.printf "communicating with %s" (show server)
  runChainSession targetChain $
    handleAction action
