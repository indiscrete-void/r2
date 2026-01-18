module R2.Encoding where

import Control.Monad
import Data.Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BC
import GHC.Generics
import Polysemy
import Polysemy.Fail

newtype Base64Text = Base64Text {unBase64 :: String}
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON) via String

bsToBase64 :: ByteString -> Base64Text
bsToBase64 = Base64Text . BC.unpack . B64.encode

base64ToBs :: Base64Text -> Either String ByteString
base64ToBs = B64.decode . BC.pack . unBase64

encodeBase64 :: (ToJSON a) => a -> Base64Text
encodeBase64 = bsToBase64 . B.toStrict . encode

decodeBase64 :: (FromJSON a) => Base64Text -> Either String a
decodeBase64 = base64ToBs >=> eitherDecodeStrict

decodeBase64Sem :: (Member Fail r, FromJSON a) => Base64Text -> Sem r a
decodeBase64Sem = either fail pure . decodeBase64
