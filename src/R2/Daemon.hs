module R2.Daemon (Log (..), msgHandler, acceptSockets, makeNodes, r2nd, r2d, logToTrace, r2Socketd, r2dIO) where

import Control.Exception (IOException)
import Control.Monad.Extra
import Control.Monad.Loops
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Daemon.Handler
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Daemon.Sockets
import R2.Daemon.Sockets.Accept
import R2.Daemon.Storage
import R2.Options
import R2.Peer
import R2.Socket
import System.Exit
import System.Posix (forkProcess)
import System.Process.Extra
import Text.Printf as Text

data Log where
  LogConnected :: Node chan -> Log
  LogRecv :: Node chan -> Message -> Log
  LogSend :: Node chan -> Message -> Log
  LogDisconnected :: Node chan -> Log
  LogError :: Node chan -> String -> Log

logShowOptionalAddr :: Maybe Address -> String
logShowOptionalAddr (Just addr) = show addr
logShowOptionalAddr Nothing = "unknown node"

logShowNode :: Node chan -> String
logShowNode node = logShowOptionalAddr (nodeAddr node)

logToTrace :: (Member Trace r) => Verbosity -> String -> InterpreterFor (Output Log) r
logToTrace verbosity cmd = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddr, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddr) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddr} -> trace $ printf "accepted %s over %s" (logShowOptionalAddr newConnAddr) (show newConnTransport)
    go (LogRecv node msg) = traceTagged (printf "<-%s" $ logShowNode node) $ case msg of
      ReqListNodes -> trace $ printf "listing connected nodes"
      ReqConnectNode transport maybeNodeID -> trace $ printf "connecting %s over %s" (logShowOptionalAddr maybeNodeID) (show transport)
      ReqTunnelProcess -> trace (printf "tunneling `%s`" cmd)
      MsgR2 (MsgRouteTo RouteTo {..}) -> when (verbosity > 1) $ trace $ printf "routing `%s` to %s" (show routeToData) (show routeToNode)
      MsgR2 (MsgRouteToErr RouteToErr {..}) -> trace $ printf "->%s: error: %s" (show routeToErrNode) routeToErrMessage
      MsgR2 (MsgRoutedFrom RoutedFrom {..}) -> when (verbosity > 1) $ trace $ printf "`%s` routed from %s" (show routedFromData) (show routedFromNode)
      msg -> when (verbosity > 0) $ trace $ printf "trace: unknown msg %s" (show msg)
    go (LogSend node msg) = traceTagged (printf "->%s" (logShowNode node)) $ case msg of
      msg@(ResNodeList _) -> trace (show msg)
      msg -> when (verbosity > 1) $ trace (show msg)
    go (LogDisconnected node) = trace $ printf "%s disconnected" (logShowNode node)
    go (LogError node err) = trace $ printf "%s error: %s" (logShowNode node) err

ioToLog :: (Member (Output Log) r) => Node chan -> Sem (Append (Transport Message Message) r) a -> Sem (Append (Transport Message Message) r) a
ioToLog node =
  intercept @(Output Message) (\(Output o) -> output (LogSend node o) >> output o)
    . intercept @(InputWithEOF Message) (\Input -> input >>= \i -> whenJust i (output . LogRecv node) >> pure i)

ioToNodeBusChanLogged :: (Member (Bus chan Message) r, Member (Output Log) r) => Node chan -> InterpretersFor (Transport Message Message) r
ioToNodeBusChanLogged node = ioToChan (nodeChan node) . ioToLog node

msgHandler ::
  ( Member (Bus chan Message) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (MakeNode chan) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r,
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
    socket @Message @Message s $ chanToIO chan

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

runLookupChan :: (Member (Storage chan) r) => InterpreterFor (LookupChan EstablishedConnection (Bidirectional chan)) r
runLookupChan = interpretLookupChanSem (\(EstablishedConnection addr) -> fmap nodeChan <$> storageLookupNode addr)

outboundChanToR2 :: (Member (Bus chan Message) r) => Outbound chan -> Outbound chan -> Address -> Sem r ()
outboundChanToR2 (Outbound routerChan) (Outbound chan) addr = do
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . putChan . Just . MsgR2 . MsgRouteTo . RouteTo addr)

reciprocateR2Connection ::
  ( Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member Async r
  ) =>
  Address ->
  Address ->
  Outbound chan ->
  Sem r (Bidirectional chan)
reciprocateR2Connection addr router routerOutboundChan = do
  chan@Bidirectional {outboundChan = Outbound -> clientOutboundChan} <- makeConnectedNode addr (R2 router)
  async_ $ outboundChanToR2 routerOutboundChan clientOutboundChan addr
  pure chan

runOverlayLookupChan ::
  ( Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  InterpreterFor (LookupChan StatelessConnection (Inbound chan)) r
runOverlayLookupChan router = interpretLookupChanSem \(StatelessConnection addr) -> do
  mStoredChan <- lookupChan (EstablishedConnection addr)
  Inbound <$> case mStoredChan of
    Just Bidirectional {inboundChan} -> pure inboundChan
    Nothing -> do
      Just (Bidirectional {outboundChan = Outbound -> routerOutboundChan}) <- lookupChan (EstablishedConnection router)
      inboundChan <$> reciprocateR2Connection addr router routerOutboundChan

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
  ( Member (Bus chan Message) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  String ->
  InterpreterFor (MakeNode chan) r
r2d self cmd = self `makeNodes` r2nd cmd

r2Socketd ::
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
r2Socketd self cmd = r2d self cmd acceptSockets

r2dIO :: Verbosity -> Bool -> Address -> Maybe FilePath -> String -> IO ()
r2dIO verbosity daemon self mSocketPath cmd =
  withR2Socket \s -> do
    addr <- r2SocketAddr mSocketPath
    IO.bind s addr
    IO.listen s 5
    forkIf daemon $
      run verbosity cmd s $
        r2Socketd self cmd
  where
    forkIf :: Bool -> IO () -> IO ()
    forkIf True m = forkProcess m >> exitSuccess
    forkIf False m = m

    runScopedSocket :: (Member (Embed IO) r, Member Trace r, Member Fail r) => Int -> InterpreterFor (Scoped IO.Socket (Bundle (Transport Message Message))) r
    runScopedSocket bufferSize =
      runScopedBundle @(Transport Message Message)
        ( \s ->
            runSocketIO bufferSize s
              . runSerialization
              . raise2Under @ByteInputWithEOF
              . raise2Under @ByteOutput
        )

    runServerSocket ::
      (Member (Embed IO) r, Member Fail r, Member Trace r) =>
      Int ->
      IO.Socket ->
      InterpretersFor
        '[ Scoped IO.Socket (Bundle (Transport Message Message)),
           Accept IO.Socket
         ]
        r
    runServerSocket bufferSize s = acceptToIO s . runScopedSocket bufferSize

    run verbosity cmd s =
      runFinal @IO
        . interpretRace
        . asyncToIOFinal
        . resourceToIOFinal
        . embedToFinal @IO
        . traceIOExceptions @IOException
        . interpretBusTBM queueSize
        . failToEmbed @IO
        -- ignore interpreter logs
        . ignoreTrace
        -- process and socket io
        . scopedProcToIOFinal bufferSize
        . runServerSocket bufferSize s
        -- AtomicRef storage
        . storageToIO
        -- log application events
        . traceToStdoutBuffered
        . logToTrace verbosity cmd
