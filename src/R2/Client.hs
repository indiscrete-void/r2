module R2.Client
  ( Log (..),
    TargetAddr (..),
    Command (..),
    Action (..),
    listNodes,
    connectNode,
    r2c,
    logToTrace,
    r2cIO,
    targetNetAddrP,
  )
where

import Control.Applicative
import Control.Exception (IOException)
import Control.Monad
import Data.ByteString (ByteString)
import Data.Maybe
import Data.Text qualified as Text
import Network.Socket qualified as IO
import Options.Applicative
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
import Polysemy.Reader
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
import System.IO
import System.Process.Extra
import Text.Printf
import Toml qualified
import Toml.Codec (TomlCodec, (.=))

newtype LocalDaemon = LocalDaemon {unLocalDaemon :: NameAddr}

data Log where
  LogMe :: NameAddr -> Log
  LogLocalDaemon :: LocalDaemon -> Log
  LogInput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogOutput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogAction :: NetworkAddr -> Action -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem \case
  (LogMe me) -> when (verbosity > 0) $ trace $ printf "me: %s" (show me)
  (LogLocalDaemon (LocalDaemon them)) -> when (verbosity > 0) $ trace $ printf "communicating with %s" (show them)
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
  | Connect !ProcessTransport !(Maybe NetworkAddr)
  | Tunnel !ProcessTransport
  | Serve (Maybe LabelAddr) !ProcessTransport
  deriving stock (Show)

data TargetAddr = TargetAddrServer | TargetAddrNetwork NetworkAddr

targetNetAddrP :: ReadM TargetAddr
targetNetAddrP = TargetAddrNetwork <$> netAddrP

targetToNetworkAddr :: NameAddr -> TargetAddr -> NetworkAddr
targetToNetworkAddr server TargetAddrServer = NetworkNameAddr server
targetToNetworkAddr server (TargetAddrNetwork target) =
  let firstAddr = netAddrHead target
   in if firstAddr == server
        then target
        else NetworkNameAddr server /> target

data Command = Command
  { commandTarget :: TargetAddr,
    commandAction :: Action
  }

newtype NodeListDaemon = NodeListDaemon
  { nodeListDaemonAddr :: String
  }
  deriving stock (Show)

newtype NodeListDaemonPeer = NodeListDaemonPeer
  { nodeListDaemonPeerAddr :: Maybe String
  }
  deriving stock (Show)

data NodeList = NodeList
  { nodeListLocalDaemon :: NodeListDaemon,
    nodeListTarget :: NodeListDaemon,
    nodeListPeers :: [NodeListDaemonPeer]
  }

daemonToNodeListPeer :: DaemonPeerInfo -> NodeListDaemonPeer
daemonToNodeListPeer DaemonPeerInfo {..} = NodeListDaemonPeer {nodeListDaemonPeerAddr = fmap show daemonPeerAddr}

nodeListDaemonCodec :: TomlCodec NodeListDaemon
nodeListDaemonCodec =
  NodeListDaemon
    <$> Toml.string "addr" .= nodeListDaemonAddr

nodeListDaemonPeerCodec :: TomlCodec NodeListDaemonPeer
nodeListDaemonPeerCodec =
  NodeListDaemonPeer
    <$> Toml.dioptional (Toml.string "addr") .= nodeListDaemonPeerAddr

nodeListPeerCodec :: TomlCodec NodeList
nodeListPeerCodec =
  NodeList
    <$> Toml.table nodeListDaemonCodec "local" .= nodeListLocalDaemon
    <*> Toml.table nodeListDaemonCodec "target" .= nodeListTarget
    <*> Toml.list nodeListDaemonPeerCodec "peer" .= nodeListPeers

listNodes ::
  ( Members (Transport DaemonToClientMessage ClientToDaemonMessage) r,
    Member (Output String) r,
    Member Fail r,
    Member (Reader LocalDaemon) r
  ) =>
  NetworkAddr ->
  Sem r ()
listNodes target = do
  localDaemon <- unLocalDaemon <$> ask
  output $ Just ReqListNodes
  (ResNodeList list) <- inputOrFail
  let nodeList =
        NodeList
          { nodeListLocalDaemon = NodeListDaemon {nodeListDaemonAddr = show localDaemon},
            nodeListTarget = NodeListDaemon {nodeListDaemonAddr = show target},
            nodeListPeers = map daemonToNodeListPeer list
          }
  output . Text.unpack $ Toml.encode nodeListPeerCodec nodeList

ioToProc ::
  ( Members (Stream 'ProcStream) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  InterpretersFor '[InputWithEOF ByteString, OutputWithEOF ByteString] r
ioToProc transport m =
  go transport $
    inToLog (LogInput transport) $
      outToLog (LogOutput transport) m
  where
    go Stdio = tagStream @'ProcStream
    go (Process cmd) = execIO (ioShell cmd) . raise2Under @Wait

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
      [ tag @'ServerStream @ByteInputWithEOF inputToOutput,
        tag @'ServerStream @ByteOutputWithEOF inputToOutput
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
  NameAddr ->
  ProcessTransport ->
  Maybe NetworkAddr ->
  Sem r ()
connectNode self transport (Just addr) = do
  tag @'ServerStream $ output $ Just $ encodeStrict $ ReqConnectNode transport addr
  ioToProc transport $ do
    routerAddr <- exchangeSelves self Nothing
    procConnChan <- makeBidirectionalChan
    Connection {connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan} <- superviseNode (Just $ NetworkNameAddr routerAddr) (Pipe transport) procConnChan
    _ <- makeR2ConnectedNode addr (NetworkNameAddr routerAddr) routerOutboundChan
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
  tag @'ServerStream $ output $ Just $ encodeStrict ReqTunnelProcess
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
  NameAddr ->
  Maybe LabelAddr ->
  ProcessTransport ->
  Sem r ()
serveTransport self mAddr transport = do
  let serviceName = case mAddr of
        Just addr -> labelAddr addr
        Nothing -> case transport of
          Stdio -> "stdio"
          Process cmd -> head $ words cmd
  let serviceAddr = NameTagAddr $ TagAddr "service" serviceName
  serviceChan <- makeBidirectionalChan
  _ <- superviseNode (Just $ NetworkNameAddr $ serviceAddr) (Pipe transport) serviceChan
  tag @'ServerStream $ output $ Just $ encodeStrict $ ReqConnectNode transport $ NetworkNameAddr $ serviceAddr
  scoped @_ @(Storage _) serviceAddr $
    runOverlay serviceAddr do
      selfChan <- makeBidirectionalChan
      _ <- superviseNode (Just $ NetworkNameAddr self) (Pipe transport) selfChan
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
    Member (Events (Event chan)) r,
    Member (Reader LocalDaemon) r
  ) =>
  NameAddr ->
  Connection chan ->
  Action ->
  Sem r ()
handleAction _ targetConn Ls = tagStream @'ServerStream $ runEncoding @DaemonToClientMessage @ClientToDaemonMessage (listNodes $ connAddr targetConn)
handleAction self _ (Connect transport maybeAddress) = connectNode self transport maybeAddress
handleAction _ _ (Tunnel transport) = connectTransport transport
handleAction self _ (Serve mAddr transport) = serveTransport self mAddr transport

meetServerAssignSelf ::
  ( Members (Stream 'ServerStream) r,
    Member Random r,
    Member Fail r,
    Member (Output Log) r
  ) =>
  Maybe NameAddr ->
  Sem r (NameAddr, LocalDaemon)
meetServerAssignSelf mSelf = do
  server <- LocalDaemon . unSelf <$> (tag @'ServerStream @ByteInputWithEOF $ decodeInput inputOrFail)
  me <- case mSelf of
    Just self -> pure self
    Nothing -> childAddr "child"
  tag @'ServerStream @ByteOutputWithEOF $ output (Just $ encodeStrict $ Self me)
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
  Maybe NameAddr ->
  Command ->
  Sem r ()
r2c mSelf (Command targetAddr action) = do
  serverChan <- makeBidirectionalChan
  async_ $ tagStream @'ServerStream $ lenDecodeInput . lenPrefixOutput $ chanToIO serverChan
  (me, server) <- streamToChan @'ServerStream serverChan $ meetServerAssignSelf mSelf
  let serverAddr = unLocalDaemon server
  let targetNetworkAddr = targetToNetworkAddr serverAddr targetAddr
  scoped @_ @(Storage _) me $ runOverlay me $ do
    output $ LogAction targetNetworkAddr action
    _ <- superviseNode (Just $ NetworkNameAddr serverAddr) Socket serverChan
    mTargetConn <- open targetNetworkAddr
    case mTargetConn of
      Just targetConn@Connection {connHighLevelChan = unHighLevel -> targetChan} ->
        streamToChan @'ServerStream targetChan do
          runReader server $ handleAction me targetConn action
      Nothing -> fail "target unreachable"

tagStream :: forall stream r a. (Members (Stream stream) r) => Sem (Append ByteTransport r) a -> Sem r a
tagStream =
  tag @stream @ByteOutputWithEOF
    . tag @stream @ByteInputWithEOF

r2cIO :: Handle -> Verbosity -> Maybe NameAddr -> FilePath -> Command -> IO ()
r2cIO traceHandle verbosity mSelf socketPath command = do
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
        . traceIOExceptions @IOException traceHandle
        . failToEmbed @IO
        -- interpreter log is ignored
        . ignoreTrace
        -- socket, std and process io
        . serverStreamToSocket bufferSize s
        . procStreamToStdio bufferSize
        . scopedProcToIOFinal bufferSize
        -- log application events
        . outputToCLI
        . traceToHandleBuffered traceHandle
        . logToTrace verbosity
        . Peer.logToTrace verbosity
        . interpretLockReentrant
        . storagesToIO
        . interpretBusTBM @ByteString queueSize
        . interpretEventsChan
        . randomToIO
