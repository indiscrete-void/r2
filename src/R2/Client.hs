module R2.Client (Command (..), Action (..), Log (..), listNodes, connectNode, r2c, logToTrace, r2cIO) where

import Control.Exception (IOException)
import Control.Monad
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Conc (interpretLockReentrant, interpretMaskFinal, interpretRace)
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource (Resource, resourceToIOFinal)
import Polysemy.Scoped
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Extra
import Polysemy.Wait
import R2
import R2.Bus
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log qualified as Peer
import R2.Peer.MakeNode
import R2.Peer.Proto
import R2.Peer.Storage
import R2.Random
import R2.Socket
import System.IO
import System.Process.Extra
import Text.Printf

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

procToIO ::
  ( Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r
  ) =>
  ProcessTransport ->
  InterpretersFor '[Input (Maybe ByteString), Output ByteString, Close] r
procToIO transport m =
  inToLog (LogInput transport) $
    outToLog (LogOutput transport) $
      go transport
  where
    go Stdio = subsume_ m
    go (Process cmd) = execIO (ioShell cmd) $ raise3Under @Wait m

procToMsg ::
  ( Member (Input (Maybe ByteString)) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output ByteString) r,
    Member (Output Log) r,
    Member (Input (Maybe Message)) r,
    Member (Output Message) r,
    Member Close r,
    Member Async r
  ) =>
  ProcessTransport ->
  Sem r ()
procToMsg transport = procToIO transport ioToMsg

connectNode ::
  ( Member Async r,
    Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r,
    Member (Bus chan Message) r,
    Member Fail r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  ProcessTransport ->
  Maybe Address ->
  Sem r ()
connectNode self transport (Just addr) = do
  output $ ReqConnectNode transport $ Just addr
  procToIO transport $ runSerialization $ do
    routerAddr <- exchangeSelves self Nothing
    procConnChan@Bidirectional {outboundChan = Outbound -> routerOutboundChan} <- makeConnectedNode routerAddr (Pipe transport)
    _ <- makeR2ConnectedNode addr routerAddr routerOutboundChan
    chanToIO procConnChan
connectNode _ _ Nothing = fail "node without addr unsupported"

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
connectTransport transport = do
  output ReqTunnelProcess
  procToMsg transport

serviceMsgHandler ::
  ( Members (Transport ByteString ByteString) r,
    Members (Transport Message Message) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output Log) r,
    Member Fail r,
    Member Async r
  ) =>
  ProcessTransport ->
  Connection chan ->
  Maybe Message ->
  Sem r ()
serviceMsgHandler transport _ msg = whenJust msg \case
  ReqTunnelProcess -> procToIO transport ioToMsg
  msg -> fail $ "unexpected message received from service " <> show msg

serveTransport ::
  ( Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Bus chan Message) r,
    Members (Transport Message Message) r,
    Member Async r,
    Member (Output Log) r,
    Member (MakeNode chan) r,
    Member (Storages chan) r,
    Member (Output Peer.Log) r,
    Member Resource r
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
  serviceChan <- makeConnectedNode serviceAddr (Pipe transport)
  output $ ReqConnectNode transport $ Just serviceAddr
  scoped @_ @(Storage _) serviceAddr $ runPeer serviceAddr (handleR2MsgDefaultAndRestWith $ serviceMsgHandler transport) do
    selfChan <- makeConnectedNode self (Pipe transport)
    linkChansBidirectional selfChan serviceChan

handleAction ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member (Output Peer.Log) r,
    Member Resource r,
    Member (Storages chan) r
  ) =>
  Address ->
  Connection chan ->
  Action ->
  Sem r ()
handleAction _ _ Ls = listNodes
handleAction self _ (Connect transport maybeAddress) = connectNode self transport maybeAddress
handleAction _ _ (Tunnel transport) = connectTransport transport
handleAction self _ (Serve mAddr transport) = serveTransport self mAddr transport

makeChain ::
  ( Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member Async r
  ) =>
  Address ->
  Outbound chan ->
  [Address] ->
  Sem r (Outbound chan)
makeChain _ routerOutboundChan [] = pure routerOutboundChan
makeChain router routerOutboundChan (target : rest) = do
  nextChan <- makeR2ConnectedNode target router routerOutboundChan
  makeChain target (Outbound $ outboundChan nextChan) rest

r2c ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Output String) r,
    Member (Bus chan Message) r,
    Member (Output Peer.Log) r,
    Member (Storages chan) r,
    Member Resource r,
    Member Random r
  ) =>
  Maybe Address ->
  Command ->
  Sem r ()
r2c mSelf (Command targetChain action) = do
  (Just server) <- fmap unSelf <$> contramapInput (>>= msgSelf) (input @(Maybe Self))
  me <- case mSelf of
    Just self -> pure self
    Nothing -> childAddr server
  output $ LogMe me
  output (MsgSelf $ Self me)
  output $ LogLocalDaemon server
  let target = case targetChain of
        [] -> server
        nodes -> last nodes
  output $ LogAction target action
  targetInboundChan <- busMakeChan
  let msgHandler Connection {connAddr} msg
        | connAddr == target = busChan targetInboundChan $ putChan msg
        | otherwise = fail $ printf "unexpected message %s from %s" (show msg) (show connAddr)
  scoped @_ @(Storage _) me $ runPeer me (handleR2MsgDefaultAndRestWith msgHandler) $ do
    serverChan <- makeConnectedNode server Socket
    async_ $ chanToIO serverChan
    Outbound targetOutboundChan <- makeChain server (Outbound $ outboundChan serverChan) targetChain
    let targetChan = Bidirectional targetInboundChan targetOutboundChan
    ioToChan @_ @Message targetChan do
      let targetConn = Connection {connAddr = target, connChan = targetChan, connTransport = Socket}
      handleAction me targetConn action

r2cIO :: Verbosity -> Maybe Address -> FilePath -> Command -> IO ()
r2cIO verbosity mSelf socketPath command = do
  withR2Socket \s -> do
    IO.connect s (IO.SockAddrUnix socketPath)
    run verbosity s $ r2c mSelf command
  where
    outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
    outputToCLI = runOutputSem (embed . putStrLn)

    runStandardIO :: (Member (Embed IO) r) => Int -> InterpretersFor (Transport ByteString ByteString) r
    runStandardIO bufferSize = closeToIO stdout . outputToIO stdout . inputToIO bufferSize stdin

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
        . (runSocketIO bufferSize s . runSerialization)
        . runStandardIO bufferSize
        . scopedProcToIOFinal bufferSize
        -- log application events
        . outputToCLI
        . traceToStderrBuffered
        . logToTrace verbosity
        . Peer.logToTrace verbosity
        . interpretLockReentrant
        . storagesToIO
        . interpretBusTBM queueSize
        . randomToIO
