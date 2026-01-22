module R2.Encoding where

import Control.Monad
import Data.Aeson
import Data.ByteString (ByteString, StrictByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import GHC.Generics
import Polysemy
import Polysemy.Fail
import R2.Encoding.LengthPrefix
import Polysemy.Transport

encodeStrict :: (ToJSON a) => a -> StrictByteString
encodeStrict = B.toStrict . encode

newtype Base64Text = Base64Text {unBase64 :: String}
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON) via String

bsToBase64 :: ByteString -> Base64Text
bsToBase64 = Base64Text . BC.unpack . B64.encode

base64ToBs :: Base64Text -> Either String ByteString
base64ToBs = B64.decode . BC.pack . unBase64

encodeBase64 :: (ToJSON a) => a -> Base64Text
encodeBase64 = bsToBase64 . encodeStrict

decodeBase64 :: (FromJSON a) => Base64Text -> Either String a
decodeBase64 = base64ToBs >=> eitherDecodeStrict

eitherToFail :: (Member Fail r) => Either String a -> Sem r a
eitherToFail = either fail pure

base64ToBsSem :: (Member Fail r) => Base64Text -> Sem r ByteString
base64ToBsSem = eitherToFail . base64ToBs

decodeStrictSem :: (Member Fail r, FromJSON a) => ByteString -> Sem r a
decodeStrictSem = eitherToFail . eitherDecodeStrict

decodeBase64Sem :: (Member Fail r, FromJSON a) => Base64Text -> Sem r a
decodeBase64Sem = eitherToFail . decodeBase64

deserializeInput :: forall a r. (FromJSON a, Member Fail r, Member ByteInputWithEOF r) => InterpreterFor (InputWithEOF a) r
deserializeInput =
  lenDecodeInput
    . reinterpret \case
      Input -> do
        mbs <- input
        case mbs of
          Just bs -> do
            i <- either fail pure $ eitherDecodeStrict bs
            pure (Just i)
          Nothing -> pure Nothing

deserializedInput :: (FromJSON i, Member Fail r) => Sem (InputWithEOF i ': r) a -> Sem (ByteInputWithEOF ': r) a
deserializedInput = deserializeInput . raiseUnder

serializeOutput :: forall a r. (ToJSON a, Member ByteOutput r) => InterpreterFor (Output a) r
serializeOutput =
  lenPrefixOutput . reinterpret \case
    Output o -> output (encodeStrict o)

serializedOutput :: (ToJSON o) => Sem (Output o ': r) a -> Sem (ByteOutput ': r) a
serializedOutput = serializeOutput . raiseUnder

runSerialization ::
  ( Member ByteInputWithEOF r,
    Member ByteOutput r,
    Member Fail r,
    FromJSON i,
    ToJSON o
  ) =>
  InterpretersFor '[InputWithEOF i, Output o] r
runSerialization = serializeOutput . deserializeInput

serialized :: (FromJSON i, ToJSON o, Member Fail r) => Sem (InputWithEOF i ': Output o ': r) a -> Sem (ByteInputWithEOF ': ByteOutput ': r) a
serialized = runSerialization . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
