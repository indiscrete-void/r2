module R2
  ( Address (..),
    RouteTo (..),
    RoutedFrom (..),
    Connection,
    Raw,
    r2,
    defaultAddr,
    parseAddressBase58,
    inputBsToRaw,
    outputBsToRaw,
  )
where

import Data.Aeson
import Data.Aeson.TH
import Data.Aeson.Types
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.DoubleWord
import Data.Text qualified as Text
import Data.Word
import GHC.Generics
import Polysemy
import Polysemy.Fail
import Polysemy.Transport
import System.Random.Stateful

newtype Address = Addr {unAddr :: Word256}
  deriving stock (Eq, Generic)
  deriving (Num) via Word256

showAddressBase58 :: Address -> String
showAddressBase58 = BC.unpack . encodeBase58 bitcoinAlphabet . integerToBS . toInteger . unAddr

parseAddressBase58 :: String -> Maybe Address
parseAddressBase58 = fmap (Addr . fromInteger . bsToInteger) . decodeBase58 bitcoinAlphabet . BC.pack

data RouteTo msg = RouteTo
  { routeToNode :: Address,
    routeToData :: msg
  }
  deriving stock (Show, Eq, Generic)

data RoutedFrom msg = RoutedFrom
  { routedFromNode :: Address,
    routedFromData :: msg
  }
  deriving stock (Show, Eq, Generic)

type Raw = Value

inputBsToRaw :: (Member ByteInputWithEOF r, Member Fail r) => InterpreterFor (InputWithEOF Raw) r
inputBsToRaw = interpret \case
  Input -> do
    input >>= \case
      Just bs -> maybe (fail "failed to decode Raw") pure . decode . LBS.fromStrict $ bs
      Nothing -> pure Nothing

outputBsToRaw :: (Member ByteOutput r) => InterpreterFor (Output Raw) r
outputBsToRaw = interpret \case
  Output o -> output . LBS.toStrict $ encode o

type Connection = ()

r2 :: (Address -> RoutedFrom msg -> a) -> (Address -> RouteTo msg -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

defaultAddr :: Address
defaultAddr = Addr 0

instance Uniform Address

instance Uniform Word128 where
  uniformM g = do
    l <- uniformM @Word64 g
    r <- uniformM @Word64 g
    pure $ Word128 l r

instance Uniform Word256 where
  uniformM g = do
    l <- uniformM @Word128 g
    r <- uniformM @Word128 g
    pure $ Word256 l r

instance Show Address where
  show (Addr addr)
    | addr == unAddr defaultAddr = "<default>"
    | otherwise = show $ encodeBase58 bitcoinAlphabet (integerToBS $ toInteger addr)

instance ToJSON Address where
  toJSON addr = String (Text.pack $ showAddressBase58 addr)

instance FromJSON Address where
  parseJSON =
    withText "Address" $
      maybe (parseFail "non-base58 string") pure
        . parseAddressBase58
        . Text.unpack

$(deriveJSON defaultOptions ''RouteTo)
$(deriveJSON defaultOptions ''RoutedFrom)
