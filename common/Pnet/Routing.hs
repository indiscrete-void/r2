module Pnet.Routing (Address, RouteTo (..), RoutedFrom (..), Connection, r2, runR2, selfAddr, defaultAddr, connectR2, acceptR2, exposeR2) where

import Data.ByteString
import Data.ByteString qualified as BS
import Data.DoubleWord
import Data.Serialize
import GHC.Generics
import Polysemy
import Polysemy.Fail
import Polysemy.Transport

type Address = Int256

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

type Connection = ()

r2 :: (Address -> RoutedFrom msg -> a) -> (Address -> RouteTo msg -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

inputBefore :: (Member (InputWithEOF i) r) => (i -> Bool) -> Sem r (Maybe i)
inputBefore f = do
  x <- input
  case x of
    Just y -> if f y then pure $ Just y else inputBefore f
    Nothing -> pure Nothing

exposeR2 :: (Members (TransportEffects (RouteTo (Maybe i)) (RoutedFrom (Maybe o))) r) => Address -> InterpretersFor (TransportEffects i o) r
exposeR2 addr =
  interpret \case Close -> outputRoutedFrom Nothing
    . interpret \case (Output msg) -> outputRoutedFrom (Just msg)
    . interpret \case Input -> (>>= routeToData) <$> inputBefore ((== addr) . routeToNode)
  where
    outputRoutedFrom :: (Member (Output (RoutedFrom msg)) r) => msg -> Sem r ()
    outputRoutedFrom = output . RoutedFrom addr

runR2 :: (Members (TransportEffects (RoutedFrom (Maybe i)) (RouteTo (Maybe o))) r) => Address -> InterpretersFor (TransportEffects i o) r
runR2 node =
  interpret \case Close -> outputRouteTo Nothing
    . interpret \case Output maybeMsg -> outputRouteTo (Just maybeMsg)
    . interpret \case Input -> (>>= routedFromData) <$> inputBefore ((== node) . routedFromNode)
  where
    outputRouteTo :: (Member (Output (RouteTo msg)) r) => msg -> Sem r ()
    outputRouteTo = output . RouteTo node

connectR2 :: (Member (Output (RouteTo Connection)) r) => Address -> Sem r ()
connectR2 addr = output $ RouteTo addr ()

acceptR2 :: (Member (InputWithEOF (RoutedFrom Connection)) r, Member Fail r) => Sem r Address
acceptR2 = routedFromNode <$> inputOrFail

selfAddr :: Address
selfAddr = -1

defaultAddr :: Address
defaultAddr = 0

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance {-# OVERLAPPING #-} Serialize (RouteTo ByteString) where
  put (RouteTo addr bs) = put addr >> put (BS.length bs) >> putByteString bs
  get = liftM2 RouteTo get (get >>= getByteString)

instance (Serialize msg) => Serialize (RouteTo msg) where
  put (RouteTo addr msg) = put (RouteTo addr (encode msg))
  get = do
    addr <- get
    _ <- get @Int
    RouteTo addr <$> get

instance {-# OVERLAPPING #-} Serialize (RoutedFrom ByteString) where
  put (RoutedFrom addr bs) = put addr >> put (BS.length bs) >> putByteString bs
  get = liftM2 RoutedFrom get (get >>= getByteString)

instance (Serialize msg) => Serialize (RoutedFrom msg) where
  put (RoutedFrom addr msg) = put (RoutedFrom addr (encode msg))
  get = do
    addr <- get
    _ <- get @Int
    RoutedFrom addr <$> get
