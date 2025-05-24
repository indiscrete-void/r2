module R2
  ( Address (..),
    RouteTo (..),
    RoutedFrom (..),
    Connection,
    Raw,
    r2,
    defaultAddr,
    parseAddressBase58,
  )
where

import Control.Monad
import Data.ByteString
import Data.ByteString qualified as BS
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Data.DoubleWord
import Data.Serialize
import Data.Word
import GHC.Generics
import System.Random.Stateful

newtype Address = Addr {unAddr :: Word256}
  deriving stock (Eq, Generic)
  deriving (Num) via Word256

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

type Raw = ByteString

type Connection = ()

r2 :: (Address -> RoutedFrom msg -> a) -> (Address -> RouteTo msg -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

defaultAddr :: Address
defaultAddr = Addr 0

instance Serialize Address

instance Serialize Word128

instance Serialize Word256

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

instance (Serialize msg) => Serialize (RouteTo msg) where
  put (RouteTo addr msg) = put (RouteTo addr (encode msg))
  get = do
    addr <- get
    _ <- get @Int
    RouteTo addr <$> get

instance {-# OVERLAPPING #-} Serialize (RouteTo Raw) where
  put (RouteTo addr bs) = put addr >> put (BS.length bs) >> putByteString bs
  get = liftM2 RouteTo get (get >>= getByteString)

instance (Serialize msg) => Serialize (RoutedFrom msg) where
  put (RoutedFrom addr msg) = put (RoutedFrom addr (encode msg))
  get = do
    addr <- get
    _ <- get @Int
    RoutedFrom addr <$> get

instance {-# OVERLAPPING #-} Serialize (RoutedFrom Raw) where
  put (RoutedFrom addr bs) = put addr >> put (BS.length bs) >> putByteString bs
  get = liftM2 RoutedFrom get (get >>= getByteString)
