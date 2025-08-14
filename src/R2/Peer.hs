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
    Transport (..),
    r2Sem,
    runR2Input,
    outputRouteTo,
    runR2Close,
    runR2Output,
    runR2,
    ioToMsg,
    ioToR2,
    transport,
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
import Data.Functor
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
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import Polysemy.Transport.Extra
import R2
import System.Environment
import System.Posix
import Text.Printf qualified as Text
import Transport.Maybe

newtype Raw = Raw {unRaw :: ByteString}
  deriving stock (Show, Generic)

instance ToJSON Raw where
  toJSON (Raw bs) = Value.String $ Text.pack $ BC.unpack bs

instance FromJSON Raw where
  parseJSON (Value.String txt) = return $ Raw $ BC.pack $ Text.unpack txt
  parseJSON _ = fail "Expected a string value"

newtype Self = Self {unSelf :: Address}
  deriving stock (Show, Generic)

$(deriveJSON defaultOptions ''Self)

data Transport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

$(deriveJSON defaultOptions ''Transport)

data Message where
  MsgSelf :: Self -> Message
  MsgRouteTo :: RouteTo Message -> Message
  MsgRoutedFrom :: RoutedFrom Message -> Message
  MsgData :: Maybe Raw -> Message -- TODO: represent conn state in raw
  ReqConnectNode :: Transport -> Maybe Address -> Message
  ReqTunnelProcess :: Message
  ReqListNodes :: Message
  ResNodeList :: [Address] -> Message
  deriving stock (Show, Generic)

$(deriveJSON defaultOptions ''Message)

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

runR2Input ::
  ( Member (InputWithEOF Message) r,
    Member Fail r,
    Member Trace r
  ) =>
  Address ->
  InterpreterFor (InputWithEOF Message) r
runR2Input node = traceTagged ("runR2Input " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case
      Input ->
        input >>= \case
          Just (MsgRoutedFrom (RoutedFrom {..})) ->
            if routedFromNode == node
              then trace (show routedFromData) $> Just routedFromData
              else fail $ "unexpected node: " <> show routedFromNode
          Just msg -> fail $ "unexected message: " <> show msg
          Nothing -> pure Nothing

outputRouteTo :: (Member (Output Message) r) => Address -> Message -> Sem r ()
outputRouteTo node = output . MsgRouteTo . RouteTo node

runR2Close ::
  forall r.
  ( Member (Output Message) r,
    Member Trace r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = traceTagged ("runR2Close " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Close -> trace "closing" >> outputRouteTo node (MsgData Nothing)

runR2Output ::
  ( Member (Output Message) r,
    Member Trace r
  ) =>
  Address ->
  InterpreterFor (Output Message) r
runR2Output node = traceTagged ("runR2Output " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Output msg -> trace (show msg) >> outputRouteTo node msg

runR2 ::
  ( Members (TransportEffects Message Message) r,
    Member Fail r,
    Member Trace r
  ) =>
  Address ->
  InterpretersFor (TransportEffects Message Message) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

runMsgInput :: (Member (InputWithEOF Message) r, Member Fail r, Member Trace r) => InterpreterFor (InputWithEOF Message) r
runMsgInput = traceTagged "runMsgInput" . go . raiseUnder @Trace
  where
    go :: (Member (InputWithEOF Message) r, Member Fail r, Member Trace r) => InterpreterFor (InputWithEOF Message) r
    go = interpret \case
      Input ->
        input >>= \case
          Just (MsgData (Just raw)) -> do
            let msg = decode @Message (LBS.fromStrict $ unRaw raw)
            trace (show msg)
            pure msg
          Just (MsgData Nothing) -> pure Nothing
          Just msg -> fail $ "unexected message: " <> show msg
          Nothing -> pure Nothing

runMsgOutput :: (Member (Output Message) r, Member Trace r) => InterpreterFor (Output Message) r
runMsgOutput = traceTagged "runMsgOutput" . go . raiseUnder @Trace
  where
    go :: (Member (Output Message) r, Member Trace r) => InterpreterFor (Output Message) r
    go = interpret \case
      Output msg -> trace (show msg) >> (output . MsgData . Just . Raw . LBS.toStrict . encode $ msg)

runMsgClose :: (Member (Output Message) r, Member Trace r) => InterpreterFor Close r
runMsgClose = traceTagged "runMsgClose" . go . raiseUnder @Trace
  where
    go :: (Member (Output Message) r, Member Trace r) => InterpreterFor Close r
    go = interpret \case
      Close -> trace "close" >> output (MsgData Nothing)

msgToIO ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member Fail r,
    Member Trace r
  ) =>
  InterpretersFor (TransportEffects Message Message) r
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
    Member Async r,
    Member Trace r
  ) =>
  Sem r ()
ioToMsg =
  sequenceConcurrently_
    [ traceTagged "msgToIn" $ contramapInput (>>= fmap unRaw . msgData) inputToOutput >> close,
      traceTagged "outToMsg" $ mapOutput (MsgData . Just . Raw) inputToOutput >> output (MsgData Nothing)
    ]

ioToR2 ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member (InputWithEOF ByteString) r,
    Member (Output ByteString) r,
    Member Fail r,
    Member Close r,
    Member Trace r,
    Member Async r
  ) =>
  Address ->
  Sem r ()
ioToR2 addr = runR2 addr ioToMsg
