module Pnet.Routing (Node, R2Message, r2) where

import Data.ByteString (ByteString)
import Data.DoubleWord
import Data.Serialize
import GHC.Generics
import Polysemy
import Polysemy.Transport

type Node = Int256

data R2Message = RouteTo Node (Maybe ByteString)
  deriving stock (Show, Generic)

r2 :: (Members '[InputWithEOF R2Message, Output R2Message, Close] r) => Node -> Node -> InterpretersFor '[InputWithEOF ByteString, Output ByteString, Close] r
r2 self node =
  interpret \case Close -> outputRouteTo Nothing
    . interpret \case Output maybeStr -> outputRouteTo (Just maybeStr)
    . interpret \case Input -> (>>= routeToSelfData) <$> input
  where
    routeToSelfData (RouteTo routeToNode maybeStr) = if routeToNode == self then maybeStr else Nothing
    outputRouteTo :: (Member (Output R2Message) r) => Maybe ByteString -> Sem r ()
    outputRouteTo = output . RouteTo node

instance Serialize Int128

instance Serialize Word128

instance Serialize Int256

instance Serialize R2Message
