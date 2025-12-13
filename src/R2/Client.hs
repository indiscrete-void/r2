module R2.Client (Command (..), Action (..), Log (..), listNodes, connectNode, r2c, logToTrace) where

import Control.Monad
import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Extra
import R2
import R2.Client.Chain
import R2.Options
import R2.Peer
import System.Process.Extra
import Text.Printf

data Action
  = Ls
  | Connect !ProcessTransport !(Maybe Address)
  | Tunnel !ProcessTransport
  deriving stock (Show)

data Command = Command
  { commandTargetChain :: [Address],
    commandAction :: Action
  }

data Log where
  LogMe :: Address -> Log
  LogLocalDaemon :: Address -> Log
  LogInput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogOutput :: ProcessTransport -> ByteString -> Log
  LogRecv :: Address -> (Maybe Message) -> Log
  LogSend :: Address -> Message -> Log
  LogAction :: Address -> Action -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem \case
  (LogMe me) -> when (verbosity > 0) $ trace $ printf "me: %s" (show me)
  (LogLocalDaemon them) -> when (verbosity > 0) $ trace $ printf "communicating with %s" (show them)
  (LogInput transport bs) -> when (verbosity > 1) $ trace $ printf "<-%s: %s" (show transport) (show bs)
  (LogOutput transport bs) -> when (verbosity > 1) $ trace $ printf "->%s: %s" (show transport) (show bs)
  (LogRecv addr bs) -> when (verbosity > 1) $ trace $ printf "<-%s: %s" (show addr) (show bs)
  (LogSend addr bs) -> when (verbosity > 1) $ trace $ printf "->%s: %s" (show addr) (show bs)
  (LogAction addr action) -> when (verbosity > 0) $ trace $ printf "running %s on %s" (show action) (show addr)

inToLog :: forall i r a. (Member (Output Log) r, Member (Input i) r) => (i -> Log) -> Sem r a -> Sem r a
inToLog f = intercept @(Input i) \case
  Input -> do
    i <- input
    output (f i)
    pure i

outToLog :: forall o r a. (Member (Output Log) r, Member (Output o) r) => (o -> Log) -> Sem r a -> Sem r a
outToLog f = intercept @(Output o) \case
  Output o -> do
    output (f o)
    output o

listNodes ::
  ( Members (Transport Message Message) r,
    Member (Output String) r,
    Member Fail r
  ) =>
  Sem r ()
listNodes = do
  output ReqListNodes
  (ResNodeList list) <- inputOrFail
  output $ show list

procToMsg ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Close r,
    Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  Sem r ()
procToMsg transport =
  let go Stdio = ioToMsg
      go (Process cmd) = execIO (ioShell cmd) ioToMsg
   in inToLog (LogInput transport) $
        outToLog (LogOutput transport) $
          go transport

connectNode ::
  ( Member Async r,
    Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode transport maybeAddress = do
  output (ReqConnectNode transport maybeAddress)
  case maybeAddress of
    Just addr ->
      inToLog (LogRecv addr) $
        outToLog (LogSend addr) $
          procToMsg transport
    Nothing ->
      procToMsg transport

connectTransport ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Output ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  Sem r ()
connectTransport transport = output ReqTunnelProcess >> procToMsg transport

handleAction ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r
  ) =>
  Action ->
  Sem r ()
handleAction Ls = listNodes
handleAction (Connect transport maybeAddress) = connectNode transport maybeAddress
handleAction (Tunnel transport) = connectTransport transport

r2c ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Output String) r
  ) =>
  Address ->
  Command ->
  Sem r ()
r2c me (Command targetChain action) = do
  output $ LogMe me
  output (MsgSelf $ Self me)
  (Just server) <- fmap unSelf <$> contramapInput (>>= msgSelf) (input @(Maybe Self))
  output $ LogLocalDaemon server
  let target = case targetChain of
        [] -> server
        nodes -> last nodes
  output $ LogAction target action
  inToLog (LogRecv server) $
    outToLog (LogSend server) $
      runChainSession targetChain $
        handleAction action
