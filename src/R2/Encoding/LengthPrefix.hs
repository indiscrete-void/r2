{-# LANGUAGE OverloadedStrings #-}

module R2.Encoding.LengthPrefix
  ( binaryDecodeStrict,
    lenDecodeInput,
    lenPrefixOutput,
  )
where

import Control.Monad.Trans.Class
import Control.Monad.Trans.Maybe
import Data.Binary (Binary)
import Data.Binary qualified as Binary
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Polysemy hiding (send)
import Polysemy.Output
import Polysemy.State (State)
import Polysemy.State qualified as State
import Polysemy.Transport

binaryDecodeStrict :: (Binary a) => ByteString -> Maybe a
binaryDecodeStrict b = do
  case Binary.decodeOrFail $ B.fromStrict b of
    Right ("", _, a) -> Just a
    _ -> Nothing

binaryEncodeStrict :: (Binary a) => a -> ByteString
binaryEncodeStrict = B.toStrict . Binary.encode

inputOrGet ::
  forall a r.
  ( Member (State (Maybe a)) r,
    Member (InputWithEOF a) r
  ) =>
  Sem r (Maybe a)
inputOrGet =
  State.get >>= \case
    Just a -> State.put @(Maybe a) Nothing >> pure (Just a)
    Nothing -> input

inputN ::
  ( Member (State (Maybe ByteString)) r,
    Member (InputWithEOF ByteString) r
  ) =>
  Int ->
  Sem r (Maybe ByteString)
inputN n = runMaybeT $ MaybeT inputOrGet >>= go
  where
    go b
      | B.length b >= n = finish b
      | otherwise = retry b

    retry leftover =
      MaybeT inputOrGet >>= \new ->
        let cumulative = leftover <> new
         in go cumulative

    finish accumulated =
      let (result, rest) = B.splitAt n accumulated
       in result <$ lift (State.put (Just rest))

lenDecodeInput :: (Member ByteInputWithEOF r) => InterpreterFor ByteInputWithEOF r
lenDecodeInput = State.evalState (Nothing :: Maybe ByteString) . go . raiseUnder
  where
    go :: (Member ByteInputWithEOF r, Member (State (Maybe ByteString)) r) => InterpreterFor ByteInputWithEOF r
    go = interpret \case
      Input -> runMaybeT do
        sizeRaw <- MaybeT (inputN 8)
        size <- hoistMaybe $ binaryDecodeStrict sizeRaw
        MaybeT $ inputN size

lenPrefixOutput :: (Member ByteOutputWithEOF r) => InterpreterFor ByteOutputWithEOF r
lenPrefixOutput = interpret \case
  Output (Just o) -> do
    let size = binaryEncodeStrict $ B.length o
    output $ Just $ size <> o
  Output Nothing -> output Nothing
