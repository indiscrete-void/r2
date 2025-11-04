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
  MsgRouteTo :: RouteTo Message -> Message
  MsgRoutedFrom :: RoutedFrom Message -> Message
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
  MsgRoutedFrom routedFrom -> Just routedFrom
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
address = str >>= maybeFail "invalid node ID" . parseAddressBase58

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
