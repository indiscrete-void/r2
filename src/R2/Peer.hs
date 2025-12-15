module R2.Peer
  ( Raw (..),
    Self (..),
    Message (..),
    r2SocketAddr,
    r2Socket,
    withR2Socket,
    bufferSize,
    queueSize,
    ProcessTransport (..),
    ioToMsg,
    processTransport,
    address,
    msgSelf,
    msgRoutedFrom,
    runMsgInput,
    runMsgOutput,
    runMsgClose,
    msgToIO,
    StatelessConnection (..),
    EstablishedConnection (..),
    routeTo,
    routeToError,
    routedFrom,
    handleR2Msg,
  )
where

import Control.Exception
import Control.Monad.Extra
import Data.Aeson
import Data.Aeson qualified as Value
import Data.Aeson.TH
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Maybe
import Data.Text qualified as Text
import Debug.Trace qualified as Debug
import GHC.Generics
import Network.Socket (Family (..), SockAddr (..), Socket, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Transport
import Polysemy.Transport.Extra
import R2
import R2.Bus
import Serial.Aeson.Options
import System.Environment
import System.Posix
import Transport.Maybe

newtype Raw = Raw {unRaw :: ByteString}
  deriving stock (Eq, Show, Generic)

instance ToJSON Raw where
  toJSON (Raw bs) = Value.String $ Text.pack $ BC.unpack bs

instance FromJSON Raw where
  parseJSON (Value.String txt) = return $ Raw $ BC.pack $ Text.unpack txt
  parseJSON _ = fail "Expected a string value"

newtype Self = Self {unSelf :: Address}
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonRemovePrefix "un") ''Self)

data ProcessTransport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''ProcessTransport)

data Message where
  MsgSelf :: Self -> Message
  MsgR2 :: R2Message Message -> Message
  MsgData :: Maybe Raw -> Message
  MsgExit :: Message
  ReqConnectNode :: ProcessTransport -> Maybe Address -> Message
  ReqTunnelProcess :: Message
  ReqListNodes :: Message
  ResNodeList :: [Address] -> Message
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''Message)

msgSelf :: Message -> Maybe Self
msgSelf = \case
  MsgSelf self -> Just self
  _ -> Nothing

msgData :: Message -> Maybe Raw
msgData = \case
  MsgData raw -> raw
  _ -> Nothing

msgRoutedFrom :: Message -> Maybe (RoutedFrom Message)
msgRoutedFrom = \case
  MsgR2 (MsgRoutedFrom routedFrom) -> Just routedFrom
  _ -> Nothing

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
withR2Socket = bracket r2Socket Socket.close

processTransport :: ReadM ProcessTransport
processTransport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = Addr <$> str

runMsgInput :: (Member (InputWithEOF Message) r, Member Fail r) => InterpreterFor ByteInputWithEOF r
runMsgInput = interpret \case
  Input ->
    input >>= \case
      Just (MsgData (Just raw)) -> pure $ Just $ unRaw raw
      Just (MsgData Nothing) -> pure Nothing
      Just msg -> fail $ "unexected message: " <> show msg
      Nothing -> pure Nothing

runMsgOutput :: (Member (Output Message) r) => InterpreterFor ByteOutput r
runMsgOutput = interpret \case
  Output msg -> output $ MsgData $ Just $ Raw msg

runMsgClose :: (Member (Output Message) r) => InterpreterFor Close r
runMsgClose = interpret \case
  Close -> output (MsgData Nothing)

msgToIO ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member Fail r
  ) =>
  InterpretersFor (Transport ByteString ByteString) r
msgToIO =
  runMsgClose
    . runMsgOutput
    . runMsgInput

ioToMsg ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member (InputWithEOF ByteString) r,
    Member (Output ByteString) r,
    Member Close r,
    Member Async r
  ) =>
  Sem r ()
ioToMsg =
  sequenceConcurrently_
    [ contramapInput (>>= fmap unRaw . msgData) inputToOutput >> close,
      mapOutput (MsgData . Just . Raw) inputToOutput >> output (MsgData Nothing)
    ]

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
