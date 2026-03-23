module R2.Client
  ( Log (..),
    TargetAddr (..),
    OfflineAction (..),
    OfflineCommand (..),
    OnlineCommand (..),
    OnlineAction (..),
    listNodes,
    connectNode,
    r2c,
    logToTrace,
    r2cIO,
    targetNetAddrP,
    r2cOfflineIO,
    Command (..),
  )
where

import Control.Exception (IOException)
import Control.Monad
import Crypto.Noise.DH.Curve25519 (Curve25519)
import Data.ByteString (ByteString)
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
import R2.Peer.Crypto (GenKey, KeyStore, genKey, genKeyToIO, keyStoreToIO, showPublicKey, storeKeyPair)
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

newtype LocalDaemon = LocalDaemon {unLocalDaemon :: AddrSet NameAddr}
  deriving stock (Show)

data Log where
  LogMe :: AddrSet NameAddr -> Log
  LogLocalDaemon :: LocalDaemon -> Log
  LogInput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogOutput :: ProcessTransport -> (Maybe ByteString) -> Log
  LogAction :: NetworkAddrSet -> OnlineAction -> Log
  LogSecretPath :: FilePath -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem \case
  (LogMe me) -> when (verbosity > 0) $ trace $ printf "me: %s" (show me)
  (LogLocalDaemon them) -> when (verbosity > 0) $ trace $ printf "communicating with %s" (show them)
  (LogInput transport bs) -> when (verbosity > 1) $ trace $ printf "<-%s: %s" (show transport) (show bs)
  (LogOutput transport bs) -> when (verbosity > 1) $ trace $ printf "->%s: %s" (show transport) (show bs)
  (LogAction addr action) -> when (verbosity > 0) $ trace $ printf "running %s on %s" (show action) (show addr)
  (LogSecretPath path) -> trace $ printf "storing secret key in %s" path

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

data OnlineAction
  = Ls
  | Connect !ProcessTransport !(AddrSet NameAddr)
  | Open !ProcessTransport
  | Serve (AddrSet LabelAddr) !ProcessTransport
  deriving stock (Show)

data OfflineAction
  = ActionGenKey
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

newtype OfflineCommand = OfflineCommand {commandOfflineAction :: OfflineAction}

data OnlineCommand = OnlineCommand {commandTarget :: TargetAddr, commandAction :: OnlineAction}

data Command
  = SomeCommandOnline OnlineCommand
  | SomeCommandOffline OfflineCommand

newtype NodeListDaemon = NodeListDaemon
  { nodeListDaemonAddr :: String
  }
  deriving stock (Show)

newtype NodeListDaemonPeer = NodeListDaemonPeer
  { nodeListDaemonPeerAddr :: String
  }
  deriving stock (Show)

data NodeList = NodeList
  { nodeListLocalDaemon :: NodeListDaemon,
    nodeListTarget :: NodeListDaemon,
    nodeListPeers :: [NodeListDaemonPeer]
  }

daemonToNodeListPeer :: DaemonPeerInfo -> NodeListDaemonPeer
daemonToNodeListPeer DaemonPeerInfo {..} = NodeListDaemonPeer {nodeListDaemonPeerAddr = show daemonPeerAddr}

nodeListDaemonCodec :: TomlCodec NodeListDaemon
nodeListDaemonCodec =
  NodeListDaemon
    <$> Toml.string "addr" .= nodeListDaemonAddr

nodeListDaemonPeerCodec :: TomlCodec NodeListDaemonPeer
nodeListDaemonPeerCodec =
  NodeListDaemonPeer
    <$> Toml.string "addr" .= nodeListDaemonPeerAddr

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
  NetworkAddrSet ->
  Sem r ()
listNodes target = do
  localDaemon <- unLocalDaemon <$> ask
  output $ Just ReqListNodes
  (ResNodeList list) <- inputOrFail
  let nodeList =
        NodeList
          { nodeListLocalDaemon = NodeListDaemon {nodeListDaemonAddr = show $ mapAddrSet NetworkNameAddr localDaemon},
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
  AddrSet NameAddr ->
  ProcessTransport ->
  AddrSet NameAddr ->
  Sem r ()
connectNode self transport addrSet = do
  ioToProc transport $ do
    routerAddr <- exchangeSelves self emptyAddrSet
    procConnChan <- makeBidirectionalChan
    let nodeAddrSet = mapAddrSet NetworkNameAddr routerAddr
    Connection {connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan} <- superviseNode nodeAddrSet (Pipe transport) procConnChan
    _ <- makeR2ConnectedNode addrSet nodeAddrSet routerOutboundChan
    tag @'ServerStream $ output $ Just $ encodeStrict $ ReqConnectNode transport addrSet
    lenDecodeInput $ lenPrefixOutput $ chanToIO procConnChan

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
  AddrSet NameAddr ->
  AddrSet LabelAddr ->
  ProcessTransport ->
  Sem r ()
serveTransport self nameSet transport = do
  let serviceNames =
        if null nameSet
          then case transport of
            Stdio -> singleAddrSet "stdio"
            Process cmd -> singleAddrSet $ head $ words cmd
          else mapAddrSet labelAddr nameSet
  let serviceAddrs = mapAddrSet (NameTagAddr . TagAddr "service") serviceNames
  serviceChan <- makeBidirectionalChan
  _ <- superviseNode (mapAddrSet NetworkNameAddr serviceAddrs) (Pipe transport) serviceChan
  tag @'ServerStream $ output $ Just $ encodeStrict $ ReqConnectNode transport serviceAddrs
  scoped @_ @(Storage _) serviceAddrs $
    runOverlay serviceAddrs do
      selfChan <- makeBidirectionalChan
      _ <- superviseNode (mapAddrSet NetworkNameAddr self) (Pipe transport) selfChan
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
  AddrSet NameAddr ->
  Connection chan ->
  OnlineAction ->
  Sem r ()
handleAction _ targetConn Ls = tagStream @'ServerStream $ runEncoding @DaemonToClientMessage @ClientToDaemonMessage (listNodes $ connAddrSet targetConn)
handleAction self _ (Connect transport addrSet) = connectNode self transport addrSet
handleAction _ _ (Open transport) = connectTransport transport
handleAction self _ (Serve addrSet transport) = serveTransport self addrSet transport

meetServerAssignSelf ::
  ( Members (Stream 'ServerStream) r,
    Member Random r,
    Member Fail r,
    Member (Output Log) r
  ) =>
  WorkerPurpose ->
  AddrSet NameAddr ->
  Sem r (AddrSet NameAddr, LocalDaemon)
meetServerAssignSelf workerPurpose selfAddrSet = do
  server <- LocalDaemon . unSelf <$> (tag @'ServerStream @ByteInputWithEOF $ decodeInput inputOrFail)
  me <-
    if null selfAddrSet
      then singleAddrSet <$> workerAddr workerPurpose
      else pure selfAddrSet
  tag @'ServerStream @ByteOutputWithEOF $ output (Just $ encodeStrict $ Self me)
  output $ LogMe me
  output $ LogLocalDaemon server
  pure (me, server)

actionToWorkerPurpose :: OnlineAction -> WorkerPurpose
actionToWorkerPurpose (Connect {}) = LinkWorker
actionToWorkerPurpose _ = GeneralWorker

handleOfflineAction :: (Member GenKey r, Member (Output String) r, Member KeyStore r, Member (Output Log) r) => OfflineAction -> Sem r ()
handleOfflineAction ActionGenKey = do
  kp@(_, public) <- genKey @_ @Curve25519
  path <- storeKeyPair kp
  output $ LogSecretPath path
  output $ show $ TagAddr x25519Tag (showPublicKey public)

r2cOffline :: (Member (Output String) r, Member (Output Log) r, Member GenKey r, Member KeyStore r) => OfflineCommand -> Sem r ()
r2cOffline (OfflineCommand action) = handleOfflineAction action

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
  AddrSet NameAddr ->
  OnlineCommand ->
  Sem r ()
r2c selfAddrs (OnlineCommand targetAddr action) = do
  serverChan <- makeBidirectionalChan
  async_ $ tagStream @'ServerStream $ lenDecodeInput . lenPrefixOutput $ chanToIO serverChan
  (me, server) <- streamToChan @'ServerStream serverChan $ meetServerAssignSelf (actionToWorkerPurpose action) selfAddrs
  let serverAddr = unLocalDaemon server
  let targetNetworkAddrs = mapAddrSet (`targetToNetworkAddr` targetAddr) serverAddr
  scoped @_ @(Storage _) me $ runOverlay me $ do
    output $ LogAction targetNetworkAddrs action
    _ <- superviseNode (mapAddrSet NetworkNameAddr serverAddr) Socket serverChan
    mTargetConn <- open targetNetworkAddrs
    case mTargetConn of
      Just targetConn@Connection {connHighLevelChan = unHighLevel -> targetChan} ->
        streamToChan @'ServerStream targetChan do
          runReader server $ handleAction me targetConn action
      Nothing -> fail "target unreachable"

tagStream :: forall stream r a. (Members (Stream stream) r) => Sem (Append ByteTransport r) a -> Sem r a
tagStream =
  tag @stream @ByteOutputWithEOF
    . tag @stream @ByteInputWithEOF

outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
outputToCLI = runOutputSem (embed . putStrLn)

r2cIO :: Handle -> Verbosity -> AddrSet NameAddr -> FilePath -> OnlineCommand -> IO ()
r2cIO traceHandle verbosity selfAddrs socketPath command = do
  withR2Socket \s -> do
    IO.connect s (IO.SockAddrUnix socketPath)
    run verbosity s $ r2c selfAddrs command
  where
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

r2cOfflineIO :: OfflineCommand -> IO ()
r2cOfflineIO = run . r2cOffline
  where
    run =
      runFinal
        . embedToFinal
        . traceToStderrBuffered
        . logToTrace 0
        . outputToCLI
        . genKeyToIO
        . keyStoreToIO
