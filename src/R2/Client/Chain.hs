module R2.Client.Chain (runChainSession) where

import Polysemy
import Polysemy.Fail
import Polysemy.Transport
import R2
import R2.Peer
import Text.Printf

runR2Input ::
  ( Member (InputWithEOF Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpreterFor (InputWithEOF Message) r
runR2Input node = interpret \case
  Input ->
    input >>= \case
      Just (MsgR2 (MsgRoutedFrom (RoutedFrom {..}))) ->
        if routedFromNode == node
          then pure $ Just routedFromData
          else fail $ "unexpected node: " <> show routedFromNode
      Just (MsgR2 (MsgRouteToErr addr err)) ->
        if addr == node
          then fail $ printf "->%s error: %s" (show addr) err
          else fail $ "unexpected node: " <> show addr
      Just msg -> fail $ "unexected message: " <> show msg
      Nothing -> pure Nothing

outputRouteTo :: (Member (Output Message) r) => Address -> Message -> Sem r ()
outputRouteTo node = output . MsgR2 . MsgRouteTo . RouteTo node

runR2Close ::
  forall r.
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor Close r
runR2Close node = interpret \case Close -> outputRouteTo node MsgExit

runR2Output ::
  ( Member (Output Message) r
  ) =>
  Address ->
  InterpreterFor (Output Message) r
runR2Output node = interpret \case Output msg -> outputRouteTo node msg

runR2 ::
  ( Members (Transport Message Message) r,
    Member Fail r
  ) =>
  Address ->
  InterpretersFor (Transport Message Message) r
runR2 node =
  runR2Close node
    . runR2Output node
    . runR2Input node

runChainSession ::
  ( Members (Transport Message Message) r,
    Member Fail r
  ) =>
  [Address] ->
  InterpretersFor (Transport Message Message) r
runChainSession [] m = subsume_ m
runChainSession (addr : rest) m =
  let mdup = insertAt @3 @(Transport Message Message) m
   in runR2 addr $ runChainSession rest mdup <* close
