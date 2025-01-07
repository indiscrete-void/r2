module Pnet.Routing
  ( Address (..),
    RouteTo (..),
    RoutedFrom (..),
    Connection,
    Raw,
    r2,
    r2Sem,
    runR2,
    runR2Input,
    runR2Output,
    runR2Close,
    defaultAddr,
    connectR2,
    acceptR2,
    Stream (..),
    ioToR2,
  )
where

import Control.Constraint
import Control.Monad
import Data.ByteString
import Data.ByteString qualified as BS
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.DoubleWord
import Data.Functor
import Data.Serialize
import Data.Word
import GHC.Generics
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import System.Random.Stateful
import Text.Printf qualified as Text

newtype Address = Addr {unAddr :: Word256}
  deriving stock (Eq, Generic)

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

r2Sem :: (Member Trace r, Show msg) => (Address -> RoutedFrom msg -> Sem r ()) -> (Address -> RouteTo msg -> Sem r ())
r2Sem f node i = traceTagged "handleR2" (trace $ Text.printf "handling %s from %s" (show i) (show node)) >> r2 f node i

inputBefore :: (Member (InputAnyWithEOF c) r, c i) => (i -> Bool) -> Sem r (Maybe i)
inputBefore f = do
  maybeX <- inputAny
  case maybeX of
    Just x ->
      if f x
        then pure $ Just x
        else inputBefore f
    Nothing -> pure Nothing

runR2Input ::
  ( Member (InputAnyWithEOF cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    cs ~ Show :&: c,
    Member Trace r
  ) =>
  Address ->
  InterpreterFor (InputAnyWithEOF cs) r
runR2Input node = traceTagged ("runR2Input " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case InputAny -> inputBefore ((== node) . routedFromNode) >>= \msg -> let msgData = msg >>= routedFromData in trace (show msgData) $> msgData

outputRouteTo :: forall msg c r. (Member (OutputAny c) r, c (RouteTo msg)) => Address -> msg -> Sem r ()
outputRouteTo node = outputAny . RouteTo node

runR2Close ::
  forall c r msg.
  ( Member (OutputAny c) r,
    msg ~ Maybe (),
    c (RouteTo msg),
    Member Trace r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = traceTagged ("runR2Close " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case Close -> trace "closing" >> outputRouteTo @msg node Nothing

runR2Output ::
  ( Member (OutputAny cs) r,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    Member Trace r,
    cs ~ Show :&: c
  ) =>
  Address ->
  InterpreterFor (OutputAny cs) r
runR2Output node = traceTagged ("runR2Output " <> show node) . go . raiseUnder @Trace
  where
    go = interpret \case OutputAny msg -> trace (show msg) >> outputRouteTo node (Just msg)

runR2 ::
  ( Members (Any cs) r,
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    c (),
    cs ~ Show :&: c,
    Member Trace r
  ) =>
  Address ->
  InterpretersFor (Any (Show :&: c)) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

connectR2 :: (Member (Output (RouteTo Connection)) r, Member Trace r) => Address -> Sem r ()
connectR2 addr = traceTagged "connectR2" (trace $ "connecting to " <> show addr) >> output (RouteTo addr ())

acceptR2 :: (Member (InputWithEOF (RoutedFrom Connection)) r, Member Fail r) => Sem r Address
acceptR2 = routedFromNode <$> inputOrFail

data Stream = R2Stream | IOStream

ioToR2 ::
  forall msg c r cs.
  ( Member (InputAnyWithEOF cs) r,
    Member (OutputAny cs) r,
    Member (InputWithEOF msg) r,
    Member (Output msg) r,
    Member Close r,
    Member Trace r,
    Member Async r,
    forall msg. (cs msg) => cs (RouteTo (Maybe msg)),
    forall msg. (cs msg) => cs (RoutedFrom (Maybe msg)),
    c (),
    cs msg,
    cs ~ Show :&: c
  ) =>
  Address ->
  Sem r ()
ioToR2 addr =
  sequenceConcurrently_
    [ runR2Input @cs addr (inputToAny $ inputToOutput @msg) >> close,
      runR2Output @cs addr (outputToAny $ inputToOutput @msg) >> runR2Close addr close
    ]

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
