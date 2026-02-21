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
import Polysemy.Transport
import Polysemy.Transport.Extra

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

decodeInput :: (Member ByteInputWithEOF r, Member Fail r, FromJSON i) => InterpreterFor (InputWithEOF i) r
decodeInput = contramapInputSem (mapM decodeStrictSem)

encodeOutput :: (Member ByteOutputWithEOF r, ToJSON o) => InterpreterFor (OutputWithEOF o) r
encodeOutput = mapOutput $ fmap encodeStrict

runEncoding ::
  forall i o r.
  ( Member ByteInputWithEOF r,
    Member ByteOutputWithEOF r,
    Member Fail r,
    FromJSON i,
    ToJSON o
  ) =>
  InterpretersFor '[InputWithEOF i, OutputWithEOF o] r
runEncoding = encodeOutput . decodeInput
