module R2.Peer
  ( resolveSocketPath,
    r2Socket,
    withR2Socket,
    bufferSize,
    queueSize,
    processTransport,
    address,
    exchangeSelves,
    OverlayConnection (..),
    EstablishedConnection (..),
    Peer,
    runPeer,
    handleR2MsgDefaultAndRestWith,
    runRouter,
  )
where

import Control.Exception qualified as IO
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.Maybe
import Debug.Trace qualified as Debug
import Network.Socket (Family (..), Socket, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Internal.Kind
import Polysemy.Resource
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.Conn
import R2.Peer.Log
import R2.Peer.MakeNode
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
    Member (Output ByteString) r,
    Member Fail r
  ) =>
  Address ->
  Maybe Address ->
  Sem r Address
exchangeSelves self maybeKnownAddr = runEncoding do
  output (Self self)
  (Self addr) <- inputOrFail
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
    Member (Bus chan ByteString) r,
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

type ConnHandlerEffects chan =
  Append
    '[ LookupChan OverlayConnection (Inbound chan),
       LookupChan EstablishedConnection (Bidirectional chan)
     ]
    (MakeNodeEffects chan)

type Peer chan =
  '[ LookupChan EstablishedConnection (Bidirectional chan),
     MakeNode chan
   ]

runPeer ::
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  ConnHandler chan (Append (ConnHandlerEffects chan) r) ->
  InterpretersFor (Peer chan) r
runPeer self userHandler = makeNodes self handler . runLookupChan
  where
    handler conn@Connection {connAddr} = runLookupChan . runOverlayLookupChan connAddr $ userHandler conn

type MsgHandler chan r = Connection chan -> Maybe ByteString -> Sem r ()

type MsgHandlerEffects chan = Transport ByteString ByteString

handleR2MsgDefaultAndRestWith ::
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan OverlayConnection (Inbound chan)) r,
    Member Fail r
  ) =>
  MsgHandler chan (Append (MsgHandlerEffects chan) r) ->
  Connection chan ->
  Sem r ()
handleR2MsgDefaultAndRestWith handleNonR2Msg conn = ioToNodeBusChanLogged (ConnectedNode conn) go
  where
    go = do
      mIn <- input
      case mIn of
        Just bs -> do
          result <- runFail $ decodeStrictSem bs
          case result of
            Right msg -> handleR2Msg (connAddr conn) msg
            Left _ -> handleNonR2Msg conn (Just bs)
          go
        Nothing -> handleNonR2Msg conn Nothing

runRouter ::
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  InterpretersFor (Peer chan) r
runRouter self = runPeer self (handleR2MsgDefaultAndRestWith nonR2MsgHandler)
  where
    nonR2MsgHandler conn msg = fail $ printf "unexpected msg from %s: %s" (show $ connAddr conn) (show msg)
