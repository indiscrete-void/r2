module Pnet.Routing (Node, RouteTo, RoutedFrom, handleR2, r2) where

import Data.ByteString (ByteString)
import Data.DoubleWord
import Data.Serialize
import GHC.Generics
import Polysemy
import Polysemy.Conc.Input
import Polysemy.Transport

type Node = Int256

data RouteTo = RouteTo
  { routeToNode :: Node,
    routeToData :: Maybe ByteString
  }
  deriving stock (Show, Generic)

data RoutedFrom = RoutedFrom
  { routedFromNode :: Node,
    routedFromData :: Maybe ByteString
  }
  deriving stock (Show, Generic)

handleR2 :: Node -> (Node -> RoutedFrom -> Sem r ()) -> (RouteTo -> Sem r ())
handleR2 node f (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr

r2 :: (Members '[InputWithEOF RoutedFrom, Output RouteTo, Close] r) => Node -> InterpretersFor '[InputWithEOF ByteString, Output ByteString, Close] r
r2 node =
  interpret \case Close -> outputRouteTo Nothing
    . interpret \case Output maybeStr -> outputRouteTo (Just maybeStr)
    . interpret \case Input -> (>>= routedFromData) <$> inputBefore ((== node) . routedFromNode)
  where
    inputBefore :: (Member (InputWithEOF i) r) => (i -> Bool) -> Sem r (Maybe i)
    inputBefore f = do
      x <- inputConc
      case x of
        Just y -> if f y then pure $ Just y else inputBefore f
        Nothing -> pure Nothing
    outputRouteTo :: (Member (Output RouteTo) r) => Maybe ByteString -> Sem r ()
    outputRouteTo = output . RouteTo node

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance Serialize RouteTo
