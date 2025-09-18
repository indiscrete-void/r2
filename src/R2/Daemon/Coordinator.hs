module R2.Daemon.Coordinator (msgHandler, acceptSockets, makeNodes, r2d) where

import Control.Monad.Extra
import Control.Monad.Loops
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Daemon
import R2.Daemon.Bus
import R2.Daemon.Handler
import R2.Daemon.MakeNode
import R2.Daemon.Sockets
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Peer
import System.Process.Extra
import Text.Printf as Text

msgHandler ::
  ( Member (NodeBus Address chan Message) r,
    Member (Bus chan Message) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (MakeNode chan) r,
    Member Fail r,
    Member Trace r,
    Member Async r,
    Member (Storage chan) r
  ) =>
  String ->
  Connection chan ->
  Sem r ()
msgHandler cmd conn@Connection {..} =
  traceTagged ("r2d handler " <> show connAddr) $
    ioToNodeBusChan connChan $
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

handleR2OutputChan ::
  ( Member (Storage chan) r,
    Member (Bus chan Message) r,
    Member Fail r
  ) =>
  Address ->
  chan ->
  Address ->
  Sem r ()
handleR2OutputChan router chan addr = do
  (Just routerNode) <- storageLookupNode router
  let routerChan = nodeBusChan ToWorld (nodeChan routerNode)
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgRouteTo . RouteTo addr)

runR2NodeBus ::
  ( Member (Storage chan) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Async r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  InterpreterFor (NodeBus Address chan Message) r
runR2NodeBus router = interpret \case
  NodeBusGetChan addr -> do
    storedNode <- storageLookupNode addr
    case storedNode of
      Just node -> pure $ nodeChan node
      Nothing -> do
        chan <- nodeBusMakeChan
        async_ $ handleR2OutputChan router (nodeBusChan ToWorld chan) addr
        let conn = Connection addr (R2 router) chan
        ioToNodeBusChan chan $ makeNode (ConnectedNode conn)
        pure chan

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
    Member (Bus chan Message) r,
    Member (Storage chan) r,
    Member Resource r,
    Member Fail r,
    Member Trace r
  ) =>
  Address ->
  (Connection chan -> Sem (MakeNode chan ': r) ()) ->
  InterpreterFor (MakeNode chan) r
makeNodes self handler = runMakeNode (async_ . go)
  where
    go :: Node chan -> Sem r ()
    go node@(AcceptedNode (NewConnection {..})) = do
      trace $ Text.printf "accepted node over %s. exchanging addresses" (show newConnTransport)
      addr <- storageLockNode node $ ioToNodeBusChan newConnChan (exchangeSelves self newConnAddr)
      let conn = Connection addr newConnTransport newConnChan
      go (ConnectedNode conn)
    go node@(ConnectedNode conn@Connection {connAddr}) = storageLockNode node do
      trace $ Text.printf "starting %s message handler" (show connAddr)
      makeNodes self handler $
        handler conn
      trace $ Text.printf "forgetting %s" (show connAddr)

r2d ::
  ( Member (Accept sock) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Resource r,
    Member Async r,
    Member Trace r,
    Member Fail r
  ) =>
  Address ->
  String ->
  Sem r ()
r2d self cmd = (self `makeNodes` r2nd) acceptSockets
  where
    r2nd conn@Connection {connAddr} = runR2NodeBus connAddr $ msgHandler cmd conn
