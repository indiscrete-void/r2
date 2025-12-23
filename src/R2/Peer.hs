module R2.Peer
  ( r2SocketAddr,
    r2Socket,
    withR2Socket,
    bufferSize,
    queueSize,
    processTransport,
    address,
    exchangeSelves,
    StatelessConnection (..),
    EstablishedConnection (..),
    routeTo,
    routeToError,
    routedFrom,
    handleR2Msg,
    runPeer,
    runRouter,
  )
where

import Control.Exception qualified as IO
import Control.Monad.Extra
import Data.Maybe
import Debug.Trace qualified as Debug
import Network.Socket (Family (..), SockAddr (..), Socket, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Reader
import Polysemy.Resource
import Polysemy.Transport
import R2
import R2.Bus
import R2.Peer.Conn
import R2.Peer.Log
import R2.Peer.MakeNode
import R2.Peer.Proto
import R2.Peer.Storage
import System.Environment
import System.Posix.User
import Text.Printf (printf)

bufferSize :: Int
bufferSize = 8192

queueSize :: Int
queueSize = 16

defaultR2SocketPath :: FilePath
defaultR2SocketPath = "/run/r2.sock"

defaultUserR2SocketPath :: IO FilePath
defaultUserR2SocketPath = go <$> getEffectiveUserID
  where
    go 0 = defaultR2SocketPath
    go n = concat ["/run/user/", show n, "/r2.sock"]

r2Socket :: IO Socket
r2Socket = socket AF_UNIX Socket.Stream Socket.defaultProtocol

r2SocketAddr :: Maybe FilePath -> IO SockAddr
r2SocketAddr customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv "PNET_SOCKET_PATH"
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  Debug.traceM ("comunicating over \"" <> path <> "\"")
  pure $ SockAddrUnix path

withR2Socket :: (Socket -> IO a) -> IO a
withR2Socket = IO.bracket r2Socket Socket.close

processTransport :: ReadM ProcessTransport
processTransport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = Addr <$> str

routeTo ::
  ( Member (Bus chan Message) r,
    Member (Output Message) r,
    Member (LookupChan EstablishedConnection (Outbound chan)) r
  ) =>
  Address ->
  RouteTo Message ->
  Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan (EstablishedConnection routeToAddr)
  case mChan of
    Just (Outbound chan) -> busChan chan $ putChan (Just $ MsgR2 $ MsgRoutedFrom routedFrom)
    Nothing -> output $ MsgR2 $ MsgRouteToErr $ RouteToErr routeToAddr "unreachable"

routeToError ::
  ( Member (Bus chan Message) r,
    Member (LookupChan EstablishedConnection (Inbound chan)) r
  ) =>
  RouteToErr ->
  Sem r ()
routeToError (RouteToErr addr _) = do
  mChan <- lookupChan (EstablishedConnection addr)
  whenJust mChan \(Inbound chan) -> busChan chan (putChan Nothing)

routedFrom ::
  ( Member (Bus chan Message) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r
  ) =>
  RoutedFrom Message ->
  Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  Inbound chan <- lookupChan (StatelessConnection routedFromNode)
  busChan chan $ putChan (Just routedFromData)

handleR2Msg ::
  ( Member (Bus chan Message) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r,
    Member (Output Message) r
  ) =>
  Address ->
  R2Message Message ->
  Sem r ()
handleR2Msg connAddr (MsgRouteTo msg) = reinterpretLookupChan (fmap $ Outbound . outboundChan) $ routeTo connAddr msg
handleR2Msg _ (MsgRouteToErr msg) = reinterpretLookupChan (fmap $ Inbound . inboundChan) $ routeToError msg
handleR2Msg _ (MsgRoutedFrom msg) = routedFrom msg

type MsgHandler chan r = Connection chan -> Message -> Sem r ()

handlePeerR2Msg ::
  ( Member (Bus chan Message) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r,
    Member (Output Message) r
  ) =>
  MsgHandler chan r ->
  Connection chan ->
  Message ->
  Sem r ()
handlePeerR2Msg _ conn (MsgR2 msg) = handleR2Msg (connAddr conn) msg
handlePeerR2Msg handleNonR2Msg conn msg = handleNonR2Msg conn msg

type MsgHandlerEffects chan = Transport Message Message

msgHandler ::
  ( Member (Bus chan Message) r,
    Member (Output Log) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan StatelessConnection (Inbound chan)) r
  ) =>
  MsgHandler chan (Append (MsgHandlerEffects chan) r) ->
  Connection chan ->
  Sem r ()
msgHandler handleNonR2Msg conn =
  ioToNodeBusChanLogged (ConnectedNode conn) $
    handle (handlePeerR2Msg handleNonR2Msg conn)

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
    when (knownNodeAddr /= addr) $ fail (printf "address mismatch")
  pure addr

type MakeNodeEffects chan =
  '[ Fail,
     MakeNode chan
   ]

type ConnHandler chan r = Connection chan -> Sem r ()

makeNodes ::
  forall chan r.
  ( Member Async r,
    Member (Output Log) r,
    Member (Bus chan Message) r,
    Member (Storage chan) r,
    Member Resource r
  ) =>
  Address ->
  ConnHandler chan (Append (MakeNodeEffects chan) r) ->
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
      inboundChan <$> makeR2ConnectedNode addr router routerOutboundChan

type ConnHandlerEffects chan =
  '[ Reader (NodeState chan),
     LookupChan StatelessConnection (Inbound chan),
     LookupChan EstablishedConnection (Bidirectional chan)
   ]

type PeerConnMsgHandlerEffects chan = Append (MsgHandlerEffects chan) (ConnHandlerEffects chan)

r2nd ::
  ( Member (Bus chan Message) r,
    Member (MakeNode chan) r,
    Member (Storage chan) r,
    Member (Output Log) r,
    Member Fail r,
    Member Async r
  ) =>
  MsgHandler chan (Append (PeerConnMsgHandlerEffects chan) r) ->
  Connection chan ->
  Sem r ()
r2nd handler conn = runMsgHandler conn $ msgHandler handler conn
  where
    runMsgHandler conn = runLookupChan . runOverlayLookupChan (connAddr conn) . nodesReaderToStorage

type PeerMsgHandlerEffects chan = Append (PeerConnMsgHandlerEffects chan) (MakeNodeEffects chan)

runPeer ::
  ( Member (Bus chan Message) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  MsgHandler chan (Append (PeerMsgHandlerEffects chan) r) ->
  InterpreterFor (MakeNode chan) r
runPeer self handler = self `makeNodes` r2nd handler

runRouter ::
  ( Member (Bus chan Message) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  InterpreterFor (MakeNode chan) r
runRouter self = runPeer self (\conn msg -> fail $ printf "unexpected msg from %s: %s" (show $ connAddr conn) (show msg))
