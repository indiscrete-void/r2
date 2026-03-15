module R2.Peer
  ( Event (..),
    resolveSocketPath,
    r2Socket,
    withR2Socket,
    bufferSize,
    queueSize,
    processTransport,
    labelAddrP,
    netAddrP,
    exchangeSelves,
    Peer,
    ChanOverlay,
    PeerChanOverlay,
    runOverlayWith,
    lookupChanToStorage,
    defaultChanOverlay,
    runOverlay,
    open,
    taggedAddrP,
    nameAddrP,
    routedAddrP,
  )
where

import Control.Exception qualified as IO
import Control.Monad.Extra
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Functor ((<&>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe
import Data.Set qualified as Set
import Network.Socket (Family (..), Socket, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Async
import Polysemy.Conc.Effect.Events
import Polysemy.Conc.Interpreter.Events
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Resource
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.Conn
import R2.Peer.Log
import R2.Peer.Proto
import R2.Peer.Routing
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

resolveSocketPath :: Maybe FilePath -> IO FilePath
resolveSocketPath customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv "R2_SOCKET"
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  pure path

withR2Socket :: (Socket -> IO a) -> IO a
withR2Socket = IO.bracket r2Socket Socket.close

processTransport :: ReadM ProcessTransport
processTransport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

labelAddrP :: ReadM LabelAddr
labelAddrP = str

taggedAddrP :: ReadM TagAddr
taggedAddrP = maybeReader parseTagAddr

nameAddrP :: ReadM NameAddr
nameAddrP = maybeReader parseNameAddr

routedAddrP :: ReadM (RoutedAddr NetworkAddr NetworkAddr)
routedAddrP = maybeReader (parseRoutedAddr parseNetAddr parseNetAddr)

netAddrP :: ReadM NetworkAddr
netAddrP = maybeReader parseNetAddr

exchangeSelves ::
  ( Member (InputWithEOF ByteString) r,
    Member (OutputWithEOF ByteString) r,
    Member Fail r
  ) =>
  AddrSet NameAddr ->
  AddrSet NameAddr ->
  Sem r (AddrSet NameAddr)
exchangeSelves self knownAddrs = runEncoding do
  output $ Just (Self self)
  (Self addrSet) <- inputOrFail
  unless (null knownAddrs) $
    unless (addrSetsReferToSameNode knownAddrs addrSet) $
      fail (printf "address mismatch")
  pure addrSet

interlayConnAddLogging ::
  (Member (Bus chan ByteString) r, Member (Output Log) r, Member Async r) =>
  NetworkAddrSet ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)
interlayConnAddLogging addrSet chan = do
  newChan <- makeBidirectionalChan
  async_ $ ioToNodeChanLogged addrSet chan $ chanToIO newChan
  pure newChan

interlayConnAddCleanup ::
  ( Member (Storage chan) r,
    Member (Bus chan d) r,
    Member Async r,
    Member (Output Log) r,
    Member (Events (Event chan)) r
  ) =>
  NetworkAddrSet ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)
interlayConnAddCleanup addrSet Bidirectional {..} = do
  let cleanup = do
        storageRmNode addrSet
        publish (ConnDestroyed addrSet)
        output (LogDisconnected addrSet)
        busPutData outboundChan Nothing
  newChan <- makeBidirectionalChan
  async_
    $ ( (inputToBusChan inboundChan . runInputSem (input >>= \mi -> when (isNothing mi) cleanup >> pure mi))
          . outputToBusChan outboundChan
      )
    $ chanToIO newChan
  pure newChan

interlayInput :: (Member (InputWithEOF ByteString) r, FromJSON a) => (a -> Sem r x) -> Sem r (Maybe ByteString)
interlayInput handle = do
  mi <- input
  case mi of
    Nothing -> pure mi
    Just bs -> do
      result <- runFail $ decodeStrictSem bs
      case result of
        Right msg -> handle msg >> interlayInput handle
        Left _ -> pure mi

interlayConnAddRouting ::
  ( Member (Peer chan) r,
    Member (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r,
    Member (Bus chan ByteString) r,
    Member Fail r,
    Member Async r,
    Member (Storage chan) r,
    Member (EventConsumer (Event chan)) r
  ) =>
  NetworkAddrSet ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)
interlayConnAddRouting addrSet chan = do
  let go = interlayInput (handleR2Msg addrSet)
  newChan <- makeBidirectionalChan
  async_ $
    ioToChan chan $
      runInputSem go $
        chanToIO newChan
  pure newChan

type ChanOverlay chan r =
  NetworkAddrSet ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)

defaultChanOverlay ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member (Peer chan) r,
    Member Fail r,
    Member (EventConsumer (Event chan)) r,
    Member (Events (Event chan)) r,
    Member Async r
  ) =>
  ChanOverlay chan r
defaultChanOverlay addr =
  interlayConnAddLogging addr
    >=> interlayConnAddCleanup addr
    >=> interlayConnAddRouting addr

insertChanOverlay ::
  ChanOverlay chan r ->
  NetworkAddrSet ->
  ConnTransport ->
  Bidirectional chan ->
  Sem r (Connection chan)
insertChanOverlay chanOverlay addr transport chan = do
  highLevelChan <- HighLevel <$> chanOverlay addr chan
  pure $
    Connection
      { connAddrSet = addr,
        connTransport = transport,
        connChan = chan,
        connHighLevelChan = highLevelChan
      }

determinePeerAddr ::
  ( Member (Storage chan) r,
    Member Fail r,
    Member (Bus chan ByteString) r,
    Member Resource r,
    Member (Output Log) r
  ) =>
  AddrSet NameAddr ->
  NetworkAddrSet ->
  Node chan ->
  Sem r NetworkAddrSet
determinePeerAddr self set node =
  if Set.null (unAddrSet set)
    then
      storageLockNode node $
        ioToNodeChanLogged
          emptyAddrSet
          (nodeChan node)
          (mapAddrSet NetworkNameAddr <$> exchangeSelves self emptyAddrSet)
    else pure set

lookupChanToStorage :: (Member (Storage chan) r) => InterpreterFor (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r
lookupChanToStorage =
  interpretLookupChanSem
    ( \(EstablishedConnection addr) -> do
        storageLookupNode (AddrSet $ Set.singleton addr) <&> \case
          Just (ConnectedNode Connection {connHighLevelChan}) -> Just connHighLevelChan
          _ -> Nothing
    )

type PeerChanOverlay chan r = ChanOverlay chan (LookupChan EstablishedConnection (HighLevel (Bidirectional chan)) ': Peer chan ': r)

makePeerNode ::
  ( Member Fail r,
    Member (Events (Event chan)) r,
    Member Resource r,
    Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member Async r,
    Member (Storage chan) r,
    Member (EventConsumer (Event chan)) r
  ) =>
  PeerChanOverlay chan r ->
  AddrSet NameAddr ->
  NetworkAddrSet ->
  ConnTransport ->
  Bidirectional chan ->
  Sem r (Connection chan)
makePeerNode chanOverlay self preAddrSet transport chan = do
  let acceptedNode = AcceptedNode (NewConnection emptyAddrSet transport chan)
  output (LogConnected acceptedNode)
  result <- runFail $ determinePeerAddr self preAddrSet acceptedNode
  case result of
    Left err -> do
      output (LogError emptyAddrSet err)
      fail err
    Right addrSet -> do
      conn <- runOverlay self $ lookupChanToStorage $ insertChanOverlay chanOverlay addrSet transport chan
      let node = ConnectedNode conn
      storageAddNode node
      publish $ ConnFullyInitialized conn
      output (LogConnected node)
      pure conn

open ::
  forall chan r.
  ( Member (Bus chan ByteString) r,
    Member (Peer chan) r,
    Member (EventConsumer (Event chan)) r,
    Member Async r,
    Member (Storage chan) r,
    Member Fail r
  ) =>
  NetworkAddrSet ->
  Sem r (Maybe (Connection chan))
open addrSet = do
  mConn <- storageLookupConn addrSet
  case mConn of
    Just conn -> pure $ Just conn
    Nothing -> openNew addrSet
  where
    openNew ::
      NetworkAddrSet ->
      Sem r (Maybe (Connection chan))
    openNew addrSet = do
      let addrList = Set.toList (unAddrSet addrSet)
      let routableAddrs = mapMaybe (\case NetworkRoutedAddr routedAddr -> Just routedAddr; _ -> Nothing) addrList
      case routableAddrs of
        [] -> pure Nothing
        (routedAddr : _) -> openRouted routedAddr

    openRouted :: RoutedAddr NetworkAddr NetworkAddr -> Sem r (Maybe (Connection chan))
    openRouted routedAddr =
      let (firstHopAddr :| rest) = netAddrToList $ NetworkRoutedAddr routedAddr
       in open (singleAddrSet $ NetworkNameAddr firstHopAddr) >>= \case
            Nothing -> pure Nothing
            Just firstHop -> go firstHop rest
      where
        go :: Connection chan -> [NameAddr] -> Sem r (Maybe (Connection chan))
        go conn [] = pure $ Just conn
        go Connection {connAddrSet = routerAddrSet, connHighLevelChan = fmap (Outbound . outboundChan) -> routerChan} (destination : rest) = do
          nextConn <- openR2ConnectedNode (singleAddrSet destination) routerAddrSet routerChan
          go nextConn rest

runOverlayWith ::
  forall chan r.
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member (Events (Event chan)) r,
    Member (EventConsumer (Event chan)) r,
    Member Async r,
    Member Resource r,
    Member Fail r
  ) =>
  PeerChanOverlay chan r ->
  AddrSet NameAddr ->
  InterpreterFor (Peer chan) r
runOverlayWith chanOverlay self m = do
  when (null self) $ fail "at least one address must be supplied"
  interpret (\case SuperviseNode addrSet transport chan -> makePeerNode chanOverlay self addrSet transport chan) m

runOverlay ::
  forall chan r.
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member (Events (Event chan)) r,
    Member (EventConsumer (Event chan)) r,
    Member Async r,
    Member Resource r,
    Member Fail r
  ) =>
  AddrSet NameAddr ->
  InterpreterFor (Peer chan) r
runOverlay = runOverlayWith defaultChanOverlay
