module R2.Daemon.Coordinator (r2nd, r2sd, r2d) where

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
import R2.Daemon.Sockets
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Peer
import System.Process.Extra
import Text.Printf as Text

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

makeNode ::
  ( Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Bus chan Message) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member Trace r,
    Member Fail r,
    Member Resource r
  ) =>
  Address ->
  String ->
  Connection chan ->
  Sem r ()
makeNode self cmd conn@(Connection {..}) = do
  async_ $
    runNewNodeBus self cmd $
      runR2NodeBus self cmd connAddr $
        r2nd cmd conn

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
  (Just routerNode) <- stateLookupNode router
  let routerChan = nodeBusChan ToWorld (connChan routerNode)
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgRouteTo . RouteTo addr)

runR2NodeBus ::
  ( Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member Trace r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  String ->
  Address ->
  InterpreterFor (NodeBus Address chan Message) r
runR2NodeBus self cmd router = interpret \case
  NodeBusGetChan addr -> do
    storedNode <- stateLookupNode addr
    case storedNode of
      Just node -> pure $ connChan node
      Nothing -> do
        chan <- nodeBusMakeChan
        async_ $ handleR2OutputChan router (nodeBusChan ToWorld chan) addr
        let conn = Connection addr (R2 router) chan
        ioToNodeBusChan chan $ makeNode self cmd conn
        pure chan

runNewNodeBus ::
  ( Member (Bus chan Message) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Fail r,
    Member Async r,
    Member Trace r,
    Member Resource r
  ) =>
  Address ->
  String ->
  InterpreterFor (NodeBus NewConnection chan Message) r
runNewNodeBus self cmd = interpret \case
  NodeBusGetChan NewConnection {..} -> do
    chan <- nodeBusMakeChan
    async_ $ ioToNodeBusChan chan $ do
      addr <- exchangeSelves self newConnAddr
      let conn = Connection addr newConnTransport chan
      makeNode self cmd conn
    pure chan

r2nd ::
  ( Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (NodeBus Address chan Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member (Bus chan Message) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member Trace r,
    Member Fail r,
    Member Resource r
  ) =>
  String ->
  Connection chan ->
  Sem r ()
r2nd cmd conn@(Connection {..}) =
  stateReflectNode conn $
    traceTagged ("r2nd " <> show connAddr) $
      handle (handleMsg cmd conn)

r2sd ::
  ( Member (Accept sock) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member (NodeBus NewConnection chan Message) r,
    Member Async r
  ) =>
  Sem r ()
r2sd =
  foreverAcceptAsync \s -> do
    socket @Message @Message s $ nodeBusToIO (NewConnection Nothing Socket)

r2d ::
  forall sock chan r.
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
r2d self cmd = runNewNodeBus self cmd r2sd
