module Polysemy.Transport.Queue (runInputQueue, runOutputQueue, runCloseQueue, runTBMQueue, runAnyTBMQueue) where

import Control.Concurrent.STM.TBMQueue
import Control.Constraint
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Typeable
import Polysemy
import Polysemy.Any
import Polysemy.Conc.Effect.Race
import Polysemy.Conc.Interpreter.Queue.TBM
import Polysemy.Conc.Queue as Queue
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Trace
import Polysemy.Transport

runInputQueue :: (Member (Queue i) r) => InterpreterFor (Input (Maybe i)) r
runInputQueue = interpret \case Input -> Queue.readMaybe

runOutputQueue :: (Member (Queue o) r) => InterpreterFor (Output o) r
runOutputQueue = interpret \case Output o -> Queue.write o

runCloseQueue :: (Member (Queue d) r) => InterpreterFor Close r
runCloseQueue = interpret \case Close -> Queue.close

runTBMQueue :: forall i o r. (Member (Embed IO) r, Member Race r) => TBMQueue i -> TBMQueue o -> InterpretersFor (TransportEffects i o) r
runTBMQueue i o =
  (interpretQueueTBMWith o . runCloseQueue . runOutputQueue . raise2Under @(Queue o))
    . (interpretQueueTBMWith i . runInputQueue . raiseUnder @(Queue i))

runAnyTBMQueue :: (Member (Embed IO) r, Member Race r, Member Fail r, Member Trace r) => TBMQueue ByteString -> TBMQueue ByteString -> InterpretersFor (Any (Show :&: FromJSON :&: ToJSON :&: Typeable)) r
runAnyTBMQueue i o = runTBMQueue i o . subsume_ . serializeAnyOutput . deserializeAnyInput . raise3Under @(InputWithEOF ByteString) . raise3Under @(Output ByteString)
