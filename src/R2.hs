module R2
  ( Address (..),
    RouteTo (..),
    RoutedFrom (..),
    RouteToErr (..),
    R2Message (..),
    r2,
    defaultAddr,
    parseAddressBase58,
  )
where

import Data.Aeson
import Data.Aeson.TH
import Data.Aeson.Types
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Data.DoubleWord
import Data.Text qualified as Text
import Data.Word
import GHC.Generics
import Serial.Aeson.Options
import System.Random.Stateful

newtype Address = Addr {unAddr :: Word256}
  deriving stock (Ord, Eq, Generic)
  deriving (Num) via Word256

showAddressBase58 :: Address -> String
showAddressBase58 = BC.unpack . encodeBase58 bitcoinAlphabet . integerToBS . toInteger . unAddr

parseAddressBase58 :: String -> Maybe Address
parseAddressBase58 = fmap (Addr . fromInteger . bsToInteger) . decodeBase58 bitcoinAlphabet . BC.pack

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
    | otherwise = BC.unpack $ encodeBase58 bitcoinAlphabet (integerToBS $ toInteger addr)

instance ToJSON Address where
  toJSON addr = String (Text.pack $ showAddressBase58 addr)

instance FromJSON Address where
  parseJSON =
    withText "Address" $
      maybe (parseFail "non-base58 string") pure
        . parseAddressBase58
        . Text.unpack

data RouteTo msg = RouteTo
  { routeToNode :: Address,
    routeToData :: msg
  }
  deriving stock (Show, Eq, Generic)

$(deriveJSON (aesonRemovePrefix "routeTo") ''RouteTo)

data RoutedFrom msg = RoutedFrom
  { routedFromNode :: Address,
    routedFromData :: msg
  }
  deriving stock (Show, Eq, Generic)

$(deriveJSON (aesonRemovePrefix "routedFrom") ''RoutedFrom)

data RouteToErr = RouteToErr
  { routeToErrNode :: Address,
    routeToErrMessage :: String
  }
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonRemovePrefix "routeToErr") ''RouteToErr)

data R2Message msg where
  MsgRouteTo :: RouteTo msg -> R2Message msg
  MsgRouteToErr :: RouteToErr -> R2Message msg
  MsgRoutedFrom :: RoutedFrom msg -> R2Message msg
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''R2Message)

r2 :: (Address -> RoutedFrom msg -> a) -> (Address -> RouteTo msg -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr
