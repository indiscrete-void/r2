module R2.Client (Log (..), Command (..), Action (..), listNodes, connectNode, r2c, logToTrace, r2cIO) where

import Control.Exception (IOException)
import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Conc (interpretLockReentrant, interpretMaskFinal, interpretRace)
import Polysemy.Conc.Effect.Events
import Polysemy.Conc.Events
import Polysemy.Conc.Interpreter.Events
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Process
import Polysemy.Resource (Resource, resourceToIOFinal)
import Polysemy.Scoped
import Polysemy.Tagged
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Wait
import R2
import R2.Bus
import R2.Client.Stream
import R2.Encoding
import R2.Encoding.LengthPrefix
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log qualified as Peer
import R2.Peer.Proto
import R2.Peer.Routing
import R2.Peer.Storage
import R2.Random
import System.Process.Extra
import Text.Printf

data Log where
  LogMe :: Address -> Log
  LogLocalDaemon :: Address -> Log
  LogInput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogOutput :: ProcessTransport -> ByteString -> Log
  LogAction :: Address -> Action -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem \case
  (LogMe me) -> when (verbosity > 0) $ trace $ printf "me: %s" (show me)
  (LogLocalDaemon them) -> when (verbosity > 0) $ trace $ printf "communicating with %s" (show them)
  (LogInput transport bs) -> when (verbosity > 1) $ trace $ printf "<-%s: %s" (show transport) (show bs)
  (LogOutput transport bs) -> when (verbosity > 1) $ trace $ printf "->%s: %s" (show transport) (show bs)
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

data Action
  = Ls
  | Connect !ProcessTransport !(Maybe Address)
  | Tunnel !ProcessTransport
  | Serve (Maybe Address) !ProcessTransport
  deriving stock (Show)

data Command = Command
  { commandTargetChain :: [Address],
    commandAction :: Action
  }

listNodes ::
  ( Members (Transport DaemonToClientMessage ClientToDaemonMessage) r,
    Member (Output String) r,
    Member Fail r
  ) =>
  Sem r ()
listNodes = do
  output ReqListNodes
  (ResNodeList list) <- inputOrFail
  output $ show list

ioToProc ::
  ( Members (Stream 'ProcStream) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  InterpretersFor '[Input (Maybe ByteString), Output ByteString, Close] r
ioToProc transport m =
  go transport $
    inToLog (LogInput transport) $
      outToLog (LogOutput transport) m
  where
    go Stdio = tagStream @'ProcStream
    go (Process cmd) = execIO (ioShell cmd) . raise3Under @Wait

procToServer ::
  ( Members (Stream 'ProcStream) r,
    Members (Stream 'ServerStream) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r,
    Member Async r
  ) =>
  ProcessTransport ->
  Sem r ()
procToServer transport =
  ioToProc transport $
    sequenceConcurrently_
      [ tag @'ServerStream @Close $ tag @'ServerStream @ByteInputWithEOF inputToOutput,
        tag @'ServerStream @(Output ByteString) inputToOutput
      ]

connectNode ::
  ( Member Async r,
    Members (Stream 'ServerStream) r,
    Members (Stream 'ProcStream) r,
    Member (EventConsumer (Event chan)) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r,
    Member (Bus chan ByteString) r,
    Member Fail r,
    Member (Peer chan) r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode self transport (Just addr) = do
  tag @'ServerStream $ output $ encodeStrict $ ReqConnectNode transport $ Just addr
  ioToProc transport $ do
    routerAddr <- exchangeSelves self Nothing
    procConnChan <- makeBidirectionalChan
    Connection {connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan} <- superviseNode (Just routerAddr) (Pipe transport) procConnChan
    _ <- makeR2ConnectedNode addr routerAddr routerOutboundChan
    lenDecodeInput $ lenPrefixOutput $ chanToIO procConnChan
connectNode _ _ Nothing = fail "node without addr unsupported"

connectTransport ::
  ( Members (Stream 'ProcStream) r,
    Members (Stream 'ServerStream) r,
    Member (Scoped CreateProcess Process) r,
    Member Async r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  Sem r ()
connectTransport transport = do
  tag @'ServerStream $ output $ encodeStrict ReqTunnelProcess
  procToServer transport

serviceMsgHandler ::
  ( Members (Stream 'ProcStream) r,
    Members ByteTransport r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r,
    Member Fail r,
    Member Async r
  ) =>
  ProcessTransport ->
  ByteString ->
  Sem r ()
serviceMsgHandler transport bs =
  decodeStrictSem bs >>= \case
    ReqTunnelProcess -> ioToStream @'ServerStream $ procToServer transport
    msg -> fail $ "unexpected message received from service " <> show msg

serveTransport ::
  ( Members (Stream 'ProcStream) r,
    Members (Stream 'ServerStream) r,
    Member (Scoped CreateProcess Process) r,
    Member (Events (Event chan)) r,
    Member (EventConsumer (Event chan)) r,
    Member (Bus chan ByteString) r,
    Member Async r,
    Member (Output Log) r,
    Member (Peer chan) r,
    Member (Storages chan) r,
    Member (Output Peer.Log) r,
    Member Resource r,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  ProcessTransport ->
  Sem r ()
serveTransport self mAddr transport = do
  let serviceAddrPart = case mAddr of
        Just addr -> addr
        Nothing -> case transport of
          Stdio -> Addr "stdio"
          Process cmd -> Addr $ head $ words cmd
  let serviceAddr = "service" /> serviceAddrPart
  serviceChan <- makeBidirectionalChan
  _ <- superviseNode (Just serviceAddr) (Pipe transport) serviceChan
  tag @'ServerStream $ output $ encodeStrict $ ReqConnectNode transport $ Just serviceAddr
  scoped @_ @(Storage _) serviceAddr $
    runPeer serviceAddr do
      selfChan <- makeBidirectionalChan
      _ <- superviseNode (Just self) (Pipe transport) selfChan
      async_ $ subscribeLoop $ \case
        ConnFullyInitialized Connection {connHighLevelChan = HighLevel highLevelChan} ->
          async_ $ ioToChan @_ @ByteString highLevelChan $ handle (serviceMsgHandler transport)
        _ -> pure ()
      linkChansBidirectional selfChan serviceChan

handleAction ::
  ( Members (Stream 'ProcStream) r,
    Members (Stream 'ServerStream) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Bus chan ByteString) r,
    Member (Peer chan) r,
    Member (Output Peer.Log) r,
    Member Resource r,
    Member (Storages chan) r,
    Member (EventConsumer (Event chan)) r,
    Member (Events (Event chan)) r
  ) =>
  Address ->
  Connection chan ->
  Action ->
  Sem r ()
handleAction _ _ Ls = tagStream @'ServerStream $ runEncoding @DaemonToClientMessage @ClientToDaemonMessage listNodes
handleAction self _ (Connect transport maybeAddress) = connectNode self transport maybeAddress
handleAction _ _ (Tunnel transport) = connectTransport transport
handleAction self _ (Serve mAddr transport) = serveTransport self mAddr transport

makeChain ::
  ( Member (Bus chan ByteString) r,
    Member (EventConsumer (Event chan)) r,
    Member (Peer chan) r,
    Member Async r
  ) =>
  Connection chan ->
  [Address] ->
  Sem r (Connection chan)
makeChain baseConn [] = pure baseConn
makeChain Connection {connAddr = router, connHighLevelChan = fmap (Outbound . outboundChan) -> baseOutboundConn} (target : rest) = do
  nextConn <- makeR2ConnectedNode target router baseOutboundConn
  makeChain nextConn rest

meetServerAssignSelf ::
  ( Members (Stream 'ServerStream) r,
    Member Random r,
    Member Fail r,
    Member (Output Log) r
  ) =>
  Maybe Address ->
  Sem r (Address, Address)
meetServerAssignSelf mSelf = do
  server <- unSelf <$> (tag @'ServerStream @ByteInputWithEOF $ lenDecodeInput $ decodeInput inputOrFail)
  me <- case mSelf of
    Just self -> pure self
    Nothing -> childAddr server
  tag @'ServerStream @ByteOutput $ lenPrefixOutput $ output (encodeStrict $ Self me)
  output $ LogMe me
  output $ LogLocalDaemon server
  pure (me, server)

r2c ::
  ( Members (Stream 'ProcStream) r,
    Members (Stream 'ServerStream) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Output String) r,
    Member (Bus chan ByteString) r,
    Member (Output Peer.Log) r,
    Member (Storages chan) r,
    Member Resource r,
    Member Random r,
    Member (EventConsumer (Event chan)) r,
    Member (Events (Event chan)) r
  ) =>
  Maybe Address ->
  Command ->
  Sem r ()
r2c mSelf (Command targetChain action) = do
  (me, server) <- meetServerAssignSelf mSelf
  let target = case targetChain of
        [] -> server
        nodes -> last nodes
  output $ LogAction target action
  scoped @_ @(Storage _) me $ runPeer me $ do
    serverChan <- makeBidirectionalChan
    serverConn <- superviseNode (Just server) Socket serverChan
    async_ $ tagStream @'ServerStream $ lenDecodeInput . lenPrefixOutput $ chanToIO serverChan
    targetConn@Connection {connHighLevelChan = unHighLevel -> targetChan} <- makeChain serverConn targetChain
    streamToChan @'ServerStream targetChan do
      handleAction me targetConn action

tagStream :: forall stream r a. (Members (Stream stream) r) => Sem (Append ByteTransport r) a -> Sem r a
tagStream =
  tag @stream @Close
    . tag @stream @ByteOutput
    . tag @stream @ByteInputWithEOF

r2cIO :: Verbosity -> Maybe Address -> FilePath -> Command -> IO ()
r2cIO verbosity mSelf socketPath command = do
  withR2Socket \s -> do
    IO.connect s (IO.SockAddrUnix socketPath)
    run verbosity s $ r2c mSelf command
  where
    outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
    outputToCLI = runOutputSem (embed . putStrLn)

    run verbosity s =
      runFinal
        . asyncToIOFinal
        . interpretMaskFinal
        . resourceToIOFinal
        . interpretRace
        . embedToFinal @IO
        . traceIOExceptions @IOException
        . failToEmbed @IO
        -- interpreter log is ignored
        . ignoreTrace
        -- socket, std and process io
        . serverStreamToSocket bufferSize s
        . procStreamToStdio bufferSize
        . scopedProcToIOFinal bufferSize
        -- log application events
        . outputToCLI
        . traceToStderrBuffered
        . logToTrace verbosity
        . Peer.logToTrace verbosity
        . interpretLockReentrant
        . storagesToIO
        . interpretBusTBM @ByteString queueSize
        . interpretEventsChan
        . randomToIO
