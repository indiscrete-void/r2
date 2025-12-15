module R2
  ( Address (..),
    RouteTo (..),
    RoutedFrom (..),
    RouteToErr (..),
    R2Message (..),
    r2,
    defaultAddr,
  )
where

import Data.Aeson
import Data.Aeson.TH
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Data.DoubleWord
import Data.Text qualified as Text
import Data.Word
import GHC.Generics
import Serial.Aeson.Options
import System.Random.Stateful

newtype Address = Addr {unAddr :: String}
  deriving stock (Ord, Eq, Generic)

instance Show Address where
  show (Addr addr) = addr

defaultAddr :: Address
defaultAddr = Addr "<default>"

instance Uniform Address where
  uniformM g = Addr . BC.unpack . encodeBase58 bitcoinAlphabet . integerToBS . toInteger <$> uniformM @Word256 g

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

instance ToJSON Address where
  toJSON (Addr addr) = String (Text.pack addr)

instance FromJSON Address where
  parseJSON = withText "Address" $ pure . Addr . Text.unpack

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
