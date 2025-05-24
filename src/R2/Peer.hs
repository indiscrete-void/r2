module R2.Peer
  ( Handshake (..),
    Self (..),
    Response (..),
    r2SocketAddr,
    r2Socket,
    withR2Socket,
    timeout,
    bufferSize,
    queueSize,
    Transport (..),
    r2Sem,
    inputBefore,
    runR2Input,
    outputRouteTo,
    runR2Close,
    runR2Output,
    connectR2,
    runR2,
    acceptR2,
    Stream (..),
    ioToR2,
    transport,
    address,
  )
where

import Control.Applicative ((<|>))
import Control.Constraint
import Control.Exception
import Data.Functor
import Data.Maybe
import Data.Serialize (Serialize)
import Debug.Trace qualified as Debug
import GHC.Generics
import Network.Socket (Family (..), SockAddr (..), Socket, setSocketOption, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import R2
import System.Environment
import System.Posix
import Text.Printf qualified as Text
import Transport.Maybe

newtype Self = Self {unSelf :: Address}
  deriving stock (Show, Generic)

data Transport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

data Handshake where
  ConnectNode :: Transport -> Maybe Address -> Handshake
  ListNodes :: Handshake
  Route :: Handshake
  TunnelProcess :: Handshake
  deriving stock (Show, Generic)

data Response where
  NodeList :: [Address] -> Response
  deriving stock (Show, Generic)

timeout :: Int
timeout = 16384

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
r2Socket = do
  s <- socket AF_UNIX Socket.Stream Socket.defaultProtocol
  setSocketOption s Socket.RecvTimeOut timeout
  setSocketOption s Socket.SendTimeOut timeout
  pure s

r2SocketAddr :: Maybe FilePath -> IO SockAddr
r2SocketAddr customPath = do
  defaultPath <- defaultUserR2SocketPath
  extraCustomPath <- lookupEnv "PNET_SOCKET_PATH"
  let path = fromMaybe defaultPath (customPath <|> extraCustomPath)
  Debug.traceM ("comunicating over \"" <> path <> "\"")
  pure $ SockAddrUnix path

withR2Socket :: (Socket -> IO a) -> IO a
withR2Socket = bracket r2Socket Socket.close

transport :: ReadM Transport
transport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = str >>= maybeFail "invalid node ID" . parseAddressBase58

r2Sem :: (Member Trace r, Show msg) => (Address -> RoutedFrom msg -> Sem r ()) -> (Address -> RouteTo msg -> Sem r ())
r2Sem f node i = traceTagged "handleR2" (trace $ Text.printf "handling %s from %s" (show i) (show node)) >> r2 f node i

inputBefore :: (Member (InputAnyWithEOF c) r, c i) => (i -> Bool) -> Sem r (Maybe i)
inputBefore f = do
  maybeX <- inputAny
  case maybeX of
    Just x ->
      if f x
        then pure $ Just x
        else inputBefore f
    Nothing -> pure Nothing

runR2Input ::
  ( Member (InputAnyWithEOF cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    cs ~ Show :&: c,
    Member Trace r
  ) =>
  Address ->
  InterpreterFor (InputAnyWithEOF cs) r
runR2Input node = traceTagged ("runR2Input " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case InputAny -> inputBefore ((== node) . routedFromNode) >>= \msg -> let msgData = msg >>= routedFromData in trace (show msgData) $> msgData

outputRouteTo :: forall msg c r. (Member (OutputAny c) r, c (RouteTo msg)) => Address -> msg -> Sem r ()
outputRouteTo node = outputAny . RouteTo node

runR2Close ::
  forall c r msg.
  ( Member (OutputAny c) r,
    msg ~ Maybe (),
    c (RouteTo msg),
    Member Trace r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = traceTagged ("runR2Close " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Close -> trace "closing" >> outputRouteTo @msg node Nothing

runR2Output ::
  ( Member (OutputAny cs) r,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    Member Trace r,
    cs ~ Show :&: c
  ) =>
  Address ->
  InterpreterFor (OutputAny cs) r
runR2Output node = traceTagged ("runR2Output " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case OutputAny msg -> trace (show msg) >> outputRouteTo node (Just msg)

runR2 ::
  ( Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    c (),
    cs ~ Show :&: c,
    Member Trace r
  ) =>
  Address ->
  InterpretersFor (Any (Show :&: c)) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

connectR2 :: (Member (Output (RouteTo Connection)) r, Member Trace r) => Address -> Sem r ()
connectR2 addr = traceTagged "connectR2" (trace $ "connecting to " <> show addr) >> output (RouteTo addr ())

acceptR2 :: (Member (InputWithEOF (RoutedFrom Connection)) r, Member Fail r) => Sem r Address
acceptR2 = routedFromNode <$> inputOrFail

data Stream = R2Stream | IOStream

ioToR2 ::
  forall msg c r cs.
  ( Member (InputAnyWithEOF cs) r,
    Member (OutputAny cs) r,
    Member (InputWithEOF msg) r,
    Member (Output msg) r,
    Member Close r,
    Member Trace r,
    Member Async r,
    forall x. (cs x) => cs (RouteTo (Maybe x)),
    forall x. (cs x) => cs (RoutedFrom (Maybe x)),
    c (),
    cs msg,
    cs ~ Show :&: c
  ) =>
  Address ->
  Sem r ()
ioToR2 addr =
  sequenceConcurrently_
    [ runR2Input @cs addr (inputToAny $ inputToOutput @msg) >> close,
      runR2Output @cs addr (outputToAny $ inputToOutput @msg) >> runR2Close addr close
    ]

instance Serialize Transport

instance Serialize Self

instance Serialize Handshake

instance Serialize Response
