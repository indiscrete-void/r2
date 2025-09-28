module R2.Client (Command (..), Action (..), listNodes, connectNode, r2c) where

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
import R2
import R2.Peer
import System.Process.Extra
import Text.Printf qualified as Text

data Action
  = Ls
  | Connect !ProcessTransport !(Maybe Address)
  | Tunnel !ProcessTransport

data Command = Command
  { commandTargetChain :: [Address],
    commandAction :: Action
  }

listNodes ::
  ( Members (Transport Message Message) r,
    Member Fail r,
    Member Trace r
  ) =>
  Sem r ()
listNodes = traceTagged "Ls" $ output ReqListNodes >> (inputOrFail @Message >>= trace . show)

procToMsg ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Close r,
    Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Async r
  ) =>
  ProcessTransport ->
  Sem r ()
procToMsg Stdio = ioToMsg
procToMsg (Process cmd) = execIO (ioShell cmd) ioToMsg

connectNode ::
  ( Member Async r,
    Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r
  ) =>
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode transport maybeAddress = output (ReqConnectNode transport maybeAddress) >> procToMsg transport

connectTransport ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Output ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Async r
  ) =>
  ProcessTransport ->
  Sem r ()
connectTransport transport = output ReqTunnelProcess >> procToMsg transport

handleAction ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Action ->
  Sem r ()
handleAction Ls = listNodes
handleAction (Connect transport maybeAddress) = connectNode transport maybeAddress
handleAction (Tunnel transport) = connectTransport transport

runR2Input ::
  ( Member (InputWithEOF Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpreterFor (InputWithEOF Message) r
runR2Input node = interpret \case
  Input ->
    input >>= \case
      Just (MsgRoutedFrom (RoutedFrom {..})) ->
        if routedFromNode == node
          then pure $ Just routedFromData
          else fail $ "unexpected node: " <> show routedFromNode
      Just msg -> fail $ "unexected message: " <> show msg
      Nothing -> pure Nothing

outputRouteTo :: (Member (Output Message) r) => Address -> Message -> Sem r ()
outputRouteTo node = output . MsgRouteTo . RouteTo node

runR2Close ::
  forall r.
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = interpret \case Close -> outputRouteTo node MsgExit

runR2Output ::
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor (Output Message) r
runR2Output node = interpret \case Output msg -> outputRouteTo node msg

runR2 ::
  ( Members (Transport Message Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpretersFor (Transport Message Message) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

runChainSession ::
  ( Members (Transport Message Message) r,
    Member Trace r,
    Member Fail r
  ) =>
  [Address] ->
  InterpretersFor (Transport Message Message) r
runChainSession [] m = subsume_ m
runChainSession (addr : rest) m =
  let mdup = insertAt @3 @(Transport Message Message) m
   in runR2 addr $ runChainSession rest mdup <* close

r2c ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Command ->
  Sem r ()
r2c me (Command targetChain action) = do
  trace $ Text.printf "me: %s" (show me)
  output (MsgSelf $ Self me)
  (Just server) <- fmap unSelf <$> contramapInput (>>= msgSelf) (input @(Maybe Self))
  trace $ Text.printf "communicating with %s" (show server)
  runChainSession targetChain $
    handleAction action
