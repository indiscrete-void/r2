module R2.Daemon (msgHandler, acceptSockets, makeNodes, r2d) where

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
import R2.Daemon.Node
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
  ( Member (Bus chan Message) r,
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
      nodeBusToStorage $
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

sendR2ChanToWorld ::
  ( Member (Storage chan) r,
    Member (Bus chan Message) r,
    Member Fail r
  ) =>
  Address ->
  chan ->
  Address ->
  Sem r ()
sendR2ChanToWorld router chan addr = do
  (Just routerNode) <- storageLookupNode router
  let routerChan = nodeBusChan ToWorld (nodeChan routerNode)
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgRouteTo . RouteTo addr)

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
    go node@(ConnectedNode conn@Connection {connAddr, connTransport, connChan}) = storageLockNode node do
      trace $ Text.printf "starting %s message handler" (show connAddr)
      case connTransport of
        R2 router -> async_ $ sendR2ChanToWorld router (nodeBusChan ToWorld connChan) connAddr
        _ -> mempty
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
r2d self cmd = (self `makeNodes` msgHandler cmd) acceptSockets
