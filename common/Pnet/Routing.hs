module Pnet.Routing (Address, RouteTo (..), RoutedFrom (..), r2, runR2) where

import Data.ByteString (ByteString)
import Data.DoubleWord
import Data.Serialize
import GHC.Generics
import Polysemy
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

r2 :: (Address -> RoutedFrom -> a) -> (Address -> RouteTo -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

runR2 :: (Members '[InputWithEOF RoutedFrom, Output RouteTo] r) => Address -> InterpretersFor '[InputWithEOF ByteString, Output ByteString, Close] r
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

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance Serialize RouteTo
