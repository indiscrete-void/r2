module Pnet.Routing (Address, RouteTo (..), RoutedFrom (..), Connection, r2, r2Sem, runR2, runR2Input, runR2Output, runR2Close, defaultAddr, connectR2, acceptR2, ioToR2) where

import Control.Monad
import Data.ByteString
import Data.ByteString qualified as BS
import Data.DoubleWord
import Data.Functor
import Data.Serialize
import Data.Word
import GHC.Generics
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import System.Random.Stateful
import Text.Printf qualified as Text

type Address = Word256

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

r2Sem :: (Show msg, Member Trace r) => (Address -> RoutedFrom msg -> Sem r ()) -> (Address -> RouteTo msg -> Sem r ())
r2Sem f node i = traceTagged "handleR2" (trace $ Text.printf "handling %s from %s" (show i) (show node)) >> r2 f node i

inputBefore :: (Member (InputWithEOF i) r) => (i -> Bool) -> Sem r (Maybe i)
inputBefore f = do
  maybeX <- input
  case maybeX of
    Just x ->
      if f x
        then pure $ Just x
        else inputBefore f
    Nothing -> pure Nothing

outputRouteTo :: (Member (Output (RouteTo msg)) r) => Address -> msg -> Sem r ()
outputRouteTo node = output . RouteTo node

runR2Close :: (Member (Output (RouteTo (Maybe o))) r, Member Trace r) => Address -> InterpreterFor Close r
runR2Close node = traceTagged ("runR2Close " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Close -> trace "closing" >> outputRouteTo node Nothing

runR2Input :: (Member (InputWithEOF (RoutedFrom (Maybe i))) r, Member Trace r, Show i) => Address -> InterpreterFor (InputWithEOF i) r
runR2Input node = traceTagged ("runR2Input " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Input -> inputBefore ((== node) . routedFromNode) >>= \msg -> let msgData = msg >>= routedFromData in trace (show msgData) $> msgData

runR2Output :: (Member (Output (RouteTo (Maybe o))) r, Member Trace r, Show o) => Address -> InterpreterFor (Output o) r
runR2Output node = traceTagged ("runR2Output " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Output msg -> trace (show msg) >> outputRouteTo node (Just msg)

runR2 :: (Members (TransportEffects (RoutedFrom (Maybe i)) (RouteTo (Maybe o))) r, Member Trace r, Show i, Show o) => Address -> InterpretersFor (TransportEffects i o) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

connectR2 :: (Member (Output (RouteTo Connection)) r, Member Trace r) => Address -> Sem r ()
connectR2 addr = traceTagged "connectR2" (trace $ "connecting to " <> show addr) >> output (RouteTo addr ())

acceptR2 :: (Member (InputWithEOF (RoutedFrom Connection)) r, Member Fail r) => Sem r Address
acceptR2 = routedFromNode <$> inputOrFail

ioToR2 :: (Member (InputWithEOF (RoutedFrom (Maybe ByteString))) r, Member ByteInputWithEOF r, Member (Output (RouteTo (Maybe ByteString))) r, Member ByteOutput r, Member Trace r, Member Async r, Member Close r) => Address -> Sem r ()
ioToR2 addr =
  sequenceConcurrently_
    [ runR2Input addr (inputToOutput @ByteString) >> close,
      runR2Output addr (inputToOutput @ByteString) >> runR2Close @ByteString addr close
    ]

defaultAddr :: Address
defaultAddr = 0

instance Serialize Word128

instance Serialize Word256

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
