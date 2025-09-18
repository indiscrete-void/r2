module R2.Peer
  ( Raw (..),
    Self (..),
    Message (..),
    r2SocketAddr,
    r2Socket,
    withR2Socket,
    timeout,
    bufferSize,
    queueSize,
    ProcessTransport (..),
    runR2Input,
    outputRouteTo,
    runR2Close,
    runR2Output,
    runR2,
    ioToMsg,
    ioToR2,
    processTransport,
    address,
    msgSelf,
    msgRoutedFrom,
    runMsgInput,
    runMsgOutput,
    runMsgClose,
    msgToIO,
  )
where

import Control.Exception
import Data.Aeson
import Data.Aeson qualified as Value
import Data.Aeson.TH
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe
import Data.Text qualified as Text
import Debug.Trace qualified as Debug
import GHC.Generics
import Network.Socket (Family (..), SockAddr (..), Socket, setSocketOption, socket)
import Network.Socket qualified as Socket
import Options.Applicative
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Transport
import Polysemy.Transport.Extra
import R2
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

$(deriveJSON (aesonOptions $ Just "un") ''Self)

data ProcessTransport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonOptions Nothing) ''ProcessTransport)

data Message where
  MsgSelf :: Self -> Message
  MsgRouteTo :: RouteTo Message -> Message
  MsgRoutedFrom :: RoutedFrom Message -> Message
  MsgData :: Maybe Raw -> Message
  ReqConnectNode :: ProcessTransport -> Maybe Address -> Message
  ReqTunnelProcess :: Message
  ReqListNodes :: Message
  ResNodeList :: [Address] -> Message
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonOptions Nothing) ''Message)

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
  MsgRoutedFrom routedFrom -> Just routedFrom
  _ -> Nothing

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

processTransport :: ReadM ProcessTransport
processTransport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = str >>= maybeFail "invalid node ID" . parseAddressBase58

runR2Input ::
  ( Member (InputWithEOF Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpreterFor (InputWithEOF Message) r
runR2Input node = interpret \case
  Input ->
    input >>= \case
      Just (MsgRoutedFrom (RoutedFrom {..})) ->
        if routedFromNode == node
          then pure $ Just routedFromData
          else fail $ "unexpected node: " <> show routedFromNode
      Just msg -> fail $ "unexected message: " <> show msg
      Nothing -> pure Nothing

outputRouteTo :: (Member (Output Message) r) => Address -> Message -> Sem r ()
outputRouteTo node = output . MsgRouteTo . RouteTo node

runR2Close ::
  forall r.
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = interpret \case Close -> outputRouteTo node (MsgData Nothing)

runR2Output ::
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor (Output Message) r
runR2Output node = interpret \case Output msg -> outputRouteTo node msg

runR2 ::
  ( Members (Transport Message Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpretersFor (Transport Message Message) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

runMsgInput :: (Member (InputWithEOF Message) r, Member Fail r) => InterpreterFor (InputWithEOF Message) r
runMsgInput = interpret \case
  Input ->
    input >>= \case
      Just (MsgData (Just raw)) -> pure $ decode @Message (LBS.fromStrict $ unRaw raw)
      Just (MsgData Nothing) -> pure Nothing
      Just msg -> fail $ "unexected message: " <> show msg
      Nothing -> pure Nothing

runMsgOutput :: (Member (Output Message) r) => InterpreterFor (Output Message) r
runMsgOutput = interpret \case
  Output msg -> (output . MsgData . Just . Raw . LBS.toStrict . encode $ msg)

runMsgClose :: (Member (Output Message) r) => InterpreterFor Close r
runMsgClose = interpret \case
  Close -> output (MsgData Nothing)

msgToIO ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member Fail r
  ) =>
  InterpretersFor (Transport Message Message) r
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

ioToR2 ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member (InputWithEOF ByteString) r,
    Member (Output ByteString) r,
    Member Fail r,
    Member Close r,
    Member Async r
  ) =>
  Address ->
  Sem r ()
ioToR2 addr = runR2 addr ioToMsg
