module Pnet.Routing (Node, RouteTo, RoutedFrom, handleR2, r2) where

import Data.ByteString (ByteString)
import Data.DoubleWord
import Data.Serialize
import GHC.Generics
import Polysemy
import Polysemy.Transport

type Node = Int256

data RouteTo = RouteTo Node (Maybe ByteString)
  deriving stock (Show, Generic)

data RoutedFrom = RoutedFrom Node (Maybe ByteString)
  deriving stock (Show, Generic)

handleR2 :: Node -> (Node -> RoutedFrom -> Sem r ()) -> (RouteTo -> Sem r ())
handleR2 node f (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

r2 :: (Members '[InputWithEOF RoutedFrom, Output RouteTo, Close] r) => Node -> InterpretersFor '[InputWithEOF ByteString, Output ByteString, Close] r
r2 node =
  interpret \case Close -> outputRouteTo Nothing
    . interpret \case Output maybeStr -> outputRouteTo (Just maybeStr)
    . interpret \case Input -> (>>= dataRoutedFromNode) <$> input
  where
    dataRoutedFromNode (RoutedFrom sender maybeStr) = if sender == node then maybeStr else Nothing
    outputRouteTo :: (Member (Output RouteTo) r) => Maybe ByteString -> Sem r ()
    outputRouteTo = output . RouteTo node

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance Serialize RouteTo
