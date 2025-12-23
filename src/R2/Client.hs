module R2.Client (Command (..), Action (..), Log (..), listNodes, connectNode, r2c, logToTrace, r2cIO) where

import Control.Exception (IOException)
import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket.Address
import Polysemy
import Polysemy.Async
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
connectTransport transport = output ReqTunnelProcess >> procToIO transport ioToMsg

handleAction ::
  ( Members (Transport Message Message) r,
    Members (Transport ByteString ByteString) r,
    Member (Scoped CreateProcess Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Async r,
    Member (Output Log) r,
    Member (Bus chan Message) r,
    Member (MakeNode chan) r
  ) =>
  Address ->
  Action ->
  Sem r ()
handleAction _ Ls = listNodes
handleAction server (Connect transport maybeAddress) = connectNode server transport maybeAddress
handleAction _ (Tunnel transport) = connectTransport transport

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
    Member (Storage chan) r,
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
        | otherwise = fail $ printf "unexepcted message %s from %s" (show msg) (show connAddr)
  runPeer me msgHandler $ do
    serverChan <- makeConnectedNode server Socket
    async_ $ chanToIO serverChan
    Outbound targetOutboundChan <- makeChain server (Outbound $ outboundChan serverChan) targetChain
    let targetChan = Bidirectional targetInboundChan targetOutboundChan
    ioToChan @_ @Message targetChan $
      handleAction target action

r2cIO :: Verbosity -> Maybe Address -> Maybe FilePath -> Command -> IO ()
r2cIO verbosity mSelf mSocketPath command = do
  withR2Socket \s -> do
    connect s =<< r2SocketAddr mSocketPath
    run verbosity s $ r2c mSelf command
  where
    outputToCLI :: (Member (Embed IO) r) => InterpreterFor (Output String) r
    outputToCLI = runOutputSem (embed . putStrLn)

    runStandardIO :: (Member (Embed IO) r) => Int -> InterpretersFor (Transport ByteString ByteString) r
    runStandardIO bufferSize = closeToIO stdout . outputToIO stdout . inputToIO bufferSize stdin

    run verbosity s =
      runFinal
        . asyncToIOFinal
        . resourceToIOFinal
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
        . Peer.logToTrace verbosity ""
        . storageToIO
        . interpretBusTBM queueSize
        . randomToIO
