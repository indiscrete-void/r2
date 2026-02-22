module R2.Peer
  ( Event (..),
    resolveSocketPath,
    r2Socket,
    withR2Socket,
    bufferSize,
    queueSize,
    processTransport,
    address,
    exchangeSelves,
    Peer,
    ChanOverlay,
    PeerChanOverlay,
    runOverlayWith,
    defaultChanOverlay,
    runOverlay,
  )
where

import Control.Exception qualified as IO
import Control.Monad.Extra
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Functor ((<&>))
import Data.Maybe
import Debug.Trace qualified as Debug
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
  Debug.traceM ("comunicating over \"" <> path <> "\"")
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

address :: ReadM Address
address = Addr <$> str

exchangeSelves ::
  ( Member (InputWithEOF ByteString) r,
    Member (OutputWithEOF ByteString) r,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  Sem r Address
exchangeSelves self maybeKnownAddr = runEncoding do
  output $ Just (Self self)
  (Self addr) <- inputOrFail
  whenJust maybeKnownAddr \knownNodeAddr ->
    when (knownNodeAddr /= addr) $ fail (printf "address mismatch")
  pure addr

interlayConnAddLogging :: (Member (Bus chan ByteString) r, Member (Output Log) r, Member Async r) => Address -> Bidirectional chan -> Sem r (Bidirectional chan)
interlayConnAddLogging addr chan = do
  newChan <- makeBidirectionalChan
  async_ $ ioToNodeChanLogged (Just addr) chan $ chanToIO newChan
  pure newChan

interlayConnAddCleanup ::
  ( Member (Storage chan) r,
    Member (Bus chan d) r,
    Member Async r,
    Member (Output Log) r,
    Member (Events (Event chan)) r
  ) =>
  Address ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)
interlayConnAddCleanup addr Bidirectional {..} = do
  let cleanup = storageRmNode (Just addr) >> publish (ConnDestroyed addr) >> output (LogDisconnected (Just addr))
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
  Address ->
  Bidirectional chan ->
  Sem r (Bidirectional chan)
interlayConnAddRouting addr chan = do
  let go = interlayInput (handleR2Msg addr)
  newChan <- makeBidirectionalChan
  async_ $
    ioToChan chan $
      runInputSem go $
        chanToIO newChan
  pure newChan

type ChanOverlay chan r =
  Address ->
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
  Address ->
  ConnTransport ->
  Bidirectional chan ->
  Sem r (Connection chan)
insertChanOverlay chanOverlay addr transport chan = do
  highLevelChan <- HighLevel <$> chanOverlay addr chan
  pure $
    Connection
      { connAddr = addr,
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
  Maybe Address ->
  Address ->
  Node chan ->
  Sem r Address
determinePeerAddr Nothing self node = storageLockNode node $ ioToNodeChanLogged Nothing (nodeChan node) (exchangeSelves self $ nodeAddr node)
determinePeerAddr (Just addr) _ _ = pure addr

lookupChanToStorage :: (Member (Storage chan) r) => InterpreterFor (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r
lookupChanToStorage =
  interpretLookupChanSem
    ( \(EstablishedConnection addr) -> do
        storageLookupNode addr <&> \case
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
  Address ->
  Maybe Address ->
  ConnTransport ->
  Bidirectional chan ->
  Sem r (Connection chan)
makePeerNode chanOverlay self mAddr transport chan = do
  let acceptedNode = AcceptedNode (NewConnection mAddr transport chan)
  output (LogConnected acceptedNode)
  result <- runFail $ determinePeerAddr mAddr self acceptedNode
  case result of
    Left err -> do
      output (LogError mAddr err)
      fail err
    Right addr -> do
      conn <- runOverlay self $ lookupChanToStorage $ insertChanOverlay chanOverlay addr transport chan
      let node = ConnectedNode conn
      storageAddNode node
      publish $ ConnFullyInitialized conn
      output (LogConnected node)
      pure conn

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
  Address ->
  InterpreterFor (Peer chan) r
runOverlayWith chanOverlay self = interpret \case
  SuperviseNode mAddr transport chan -> makePeerNode chanOverlay self mAddr transport chan

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
  Address ->
  InterpreterFor (Peer chan) r
runOverlay = runOverlayWith defaultChanOverlay
