module R2.Peer.Proto
  ( Raw (..),
    Self (..),
    ProcessTransport (..),
    Message (..),
    ioToMsg,
    msgSelf,
    msgRoutedFrom,
    runMsgInput,
    runMsgOutput,
    runMsgClose,
    inputMsgOutputBs,
    inputBsOutputMsg,
    msgToIO,
  )
where

import Data.Aeson
import Data.Aeson qualified as Value
import Data.Aeson.TH
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as Text
import GHC.Generics
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Transport
import Polysemy.Transport.Extra
import R2
import R2.Encoding (Base64Text)
import Serial.Aeson.Options

data ProcessTransport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''ProcessTransport)

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

data Message where
  MsgSelf :: Self -> Message
  MsgR2 :: R2Message Base64Text -> Message
  MsgData :: Maybe Raw -> Message
  MsgExit :: Message
  ReqConnectNode :: ProcessTransport -> Maybe Address -> Message
  ReqTunnelProcess :: Message
  ResTunnelProcess :: Address -> Message
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

msgRoutedFrom :: Message -> Maybe (RoutedFrom Base64Text)
msgRoutedFrom = \case
  MsgR2 (MsgRoutedFrom routedFrom) -> Just routedFrom
  _ -> Nothing

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

inputMsgOutputBs :: (Member (InputWithEOF Message) r, Member ByteOutput r, Member Close r) => Sem r ()
inputMsgOutputBs = contramapInput (>>= fmap unRaw . msgData) inputToOutput >> close

inputBsOutputMsg :: (Member ByteInputWithEOF r, Member (Output Message) r) => Sem r ()
inputBsOutputMsg = mapOutput (MsgData . Just . Raw) inputToOutput >> output (MsgData Nothing)

ioToMsg ::
  ( Member (InputWithEOF Message) r,
    Member (Output Message) r,
    Member (InputWithEOF ByteString) r,
    Member (Output ByteString) r,
    Member Close r,
    Member Async r
  ) =>
  Sem r ()
ioToMsg = sequenceConcurrently_ [inputMsgOutputBs, inputBsOutputMsg]
