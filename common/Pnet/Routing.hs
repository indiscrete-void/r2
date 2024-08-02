module Pnet.Routing (Address, ConnectTo (..), ConnectionFrom (..), RouteTo (..), RoutedFrom (..), r2, runR2, selfAddr, defaultAddr, matchR2, connectTo, acceptR2) where

import Data.ByteString (ByteString)
import Data.DoubleWord
import Data.Serialize hiding (Fail, get)
import GHC.Generics
import Polysemy
import Polysemy.Fail
import Polysemy.Transport

type Address = Int256

data RouteTo = RouteTo
  { routeToNode :: Address,
    routeToData :: Maybe ByteString
  }
  deriving stock (Show, Eq, Generic)

data RoutedFrom = RoutedFrom
  { routedFromNode :: Address,
    routedFromData :: Maybe ByteString
  }
  deriving stock (Show, Eq, Generic)

newtype ConnectTo = ConnectTo
  { connectToNode :: Address
  }
  deriving stock (Show, Eq, Generic)

newtype ConnectionFrom = ConnectionFrom
  { connectionFromNode :: Address
  }
  deriving stock (Show, Eq, Generic)

r2 :: (Address -> RoutedFrom -> a) -> (Address -> RouteTo -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

runR2 :: (Members (TransportEffects RoutedFrom RouteTo) r) => Address -> InterpretersFor (TransportEffects ByteString ByteString) r
runR2 node =
  interpret \case Close -> outputRouteTo Nothing
    . interpret \case Output maybeStr -> outputRouteTo (Just maybeStr)
    . interpret \case Input -> (>>= routedFromData) <$> inputBefore ((== node) . routedFromNode)
  where
    inputBefore :: (Member (InputWithEOF i) r) => (i -> Bool) -> Sem r (Maybe i)
    inputBefore f = do
      x <- input
      case x of
        Just y -> if f y then pure $ Just y else inputBefore f
        Nothing -> pure Nothing
    outputRouteTo :: (Member (Output RouteTo) r) => Maybe ByteString -> Sem r ()
    outputRouteTo = output . RouteTo node

connectTo :: (Member (Output ConnectTo) r) => Address -> Sem r ()
connectTo = output . ConnectTo

matchR2 :: (Address -> ConnectionFrom -> a) -> (Address -> ConnectTo -> a)
matchR2 f node (ConnectTo receiver) = f receiver $ ConnectionFrom node

acceptR2 :: (Member (InputWithEOF ConnectionFrom) r, Member Fail r) => Sem r Address
acceptR2 = connectionFromNode <$> inputOrFail

selfAddr :: Address
selfAddr = -1

defaultAddr :: Address
defaultAddr = 0

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance Serialize RouteTo

instance Serialize RoutedFrom
