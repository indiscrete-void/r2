module R2.Daemon (Log (..), msgHandler, acceptSockets, makeNodes, r2d) where

import Control.Monad.Extra
import Control.Monad.Loops
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.Transport
import R2
import R2.Daemon.Bus
import R2.Daemon.Handler
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Daemon.Sockets
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Peer
import System.Process.Extra
import Text.Printf as Text

data Log where
  LogConnected :: Node chan -> Log
  LogRecv :: Node chan -> Message -> Log
  LogSend :: Node chan -> Message -> Log
  LogDisconnected :: Node chan -> Log
  LogError :: Node chan -> String -> Log

ioToLog :: (Member (Output Log) r) => Node chan -> Sem (Append (Transport Message Message) r) a -> Sem (Append (Transport Message Message) r) a
ioToLog node =
  intercept @(Output Message) (\(Output o) -> output (LogSend node o) >> output o)
    . intercept @(InputWithEOF Message) (\Input -> input >>= \i -> whenJust i (output . LogRecv node) >> pure i)

ioToNodeBusChanLogged :: (Member (Bus chan Message) r, Member (Output Log) r) => Node chan -> InterpretersFor (Transport Message Message) r
ioToNodeBusChanLogged node = ioToNodeBusChan (nodeChan node) . ioToLog node

msgHandler ::
  ( Member (Bus chan Message) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (MakeNode chan) r,
    Member (LookupChan EstablishedConnection (Maybe chan)) r,
    Member (LookupChan StatelessConnection chan) r,
    Member (Storage chan) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r
  ) =>
  String ->
  Connection chan ->
  Sem r ()
msgHandler cmd conn =
  ioToNodeBusChanLogged (ConnectedNode conn) $
    nodesReaderToStorage $
      handle (handleMsg cmd conn)

exchangeSelves ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  Sem r Address
exchangeSelves self maybeKnownAddr = do
  output (MsgSelf $ Self self)
  (Just (Self addr)) <- msgSelf <$> inputOrFail
  whenJust maybeKnownAddr \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (Text.printf "address mismatch")
  pure addr

acceptSockets ::
  ( Member (Accept sock) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Async r,
    Member (MakeNode chan) r
  ) =>
  Sem r ()
acceptSockets =
  foreverAcceptAsync \s -> do
    chan <- makeAcceptedNode Nothing Socket
    socket @Message @Message s $ nodeBusChanToIO chan

makeNodes ::
  forall chan r.
  ( Member Async r,
    Member (Output Log) r,
    Member (Bus chan Message) r,
    Member (Storage chan) r,
    Member Resource r
  ) =>
  Address ->
  (Connection chan -> Sem (Fail ': MakeNode chan ': r) ()) ->
  InterpreterFor (MakeNode chan) r
makeNodes self handler = runMakeNode (async_ . go)
  where
    go :: Node chan -> Sem r ()
    go node@(AcceptedNode NewConnection {..}) = do
      output (LogConnected node)
      result <- runFail $ storageLockNode node $ ioToNodeBusChanLogged node (exchangeSelves self newConnAddr)
      case result of
        Right addr -> go (ConnectedNode $ Connection addr newConnTransport newConnChan)
        Left err -> output (LogError node err)
    go node@(ConnectedNode conn) = storageLockNode node do
      output (LogConnected node)
      result <-
        makeNodes self handler $
          runFail $
            handler conn
      output $ case result of
        Right () -> LogDisconnected node
        Left err -> LogError node err

runLookupChan :: (Member (Storage chan) r) => InterpreterFor (LookupChan EstablishedConnection (Maybe chan)) r
runLookupChan = interpret \case LookupChan dir (EstablishedConnection addr) -> fmap (nodeBusChan dir . nodeChan) <$> storageLookupNode addr

outboundChanToR2 ::
  ( Member (Bus chan Message) r,
    Member (LookupChan EstablishedConnection (Maybe chan)) r,
    Member Fail r
  ) =>
  Address ->
  chan ->
  Address ->
  Sem r ()
outboundChanToR2 router chan addr = do
  Just routerChan <- lookupChan ToWorld (EstablishedConnection router)
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgR2 . MsgRouteTo . RouteTo addr)

runOverlayLookupChan ::
  ( Member (LookupChan EstablishedConnection (Maybe chan)) r,
    Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  InterpreterFor (LookupChan StatelessConnection chan) r
runOverlayLookupChan router = interpret \case
  LookupChan dir (StatelessConnection addr) -> do
    let makeChan = do
          chan <- makeConnectedNode addr (R2 router)
          async_ $ outboundChanToR2 router (nodeBusChan ToWorld chan) addr
          pure $ nodeBusChan dir chan
    storedChan <- lookupChan dir (EstablishedConnection addr)
    maybe makeChan pure storedChan

r2nd ::
  ( Member (Bus chan Message) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (MakeNode chan) r,
    Member (Storage chan) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r
  ) =>
  String ->
  Connection chan ->
  Sem r ()
r2nd cmd conn = runLookupChan $ runOverlayLookupChan (connAddr conn) $ msgHandler cmd conn

r2d ::
  ( Member (Accept sock) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Resource r,
    Member Async r,
    Member (Output Log) r
  ) =>
  Address ->
  String ->
  Sem r ()
r2d self cmd = (self `makeNodes` r2nd cmd) acceptSockets
