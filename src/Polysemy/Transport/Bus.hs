module Polysemy.Transport.Bus (RecvFrom, SendTo, sendTo, recvdFrom, recvFrom, interpretRecvFromTBMQueue, inputToQueue) where

import Control.Concurrent.STM.TBMQueue
import Data.List qualified as List
import Polysemy
import Polysemy.Conc (Race)
import Polysemy.Conc.Effect.Lock
import Polysemy.Conc.Interpreter.Queue.TBM
import Polysemy.Conc.Queue
import Polysemy.Conc.Queue qualified as Queue
import Polysemy.Input
import Polysemy.Output
import Polysemy.Scoped
import Polysemy.State
import Polysemy.State qualified as State
import Polysemy.Transport

type RecvFrom addr i = Scoped addr (Queue i)

type SendTo addr o = Scoped addr (Output o)

sendTo :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
sendTo = scoped

recvFrom :: (Member (RecvFrom addr i) r) => addr -> InterpreterFor (Queue i) r
recvFrom = scoped

recvdFrom :: (Member (RecvFrom addr i) r) => addr -> i -> Sem r ()
recvdFrom addr = recvFrom addr . Queue.write

type RecvFromTBMQueues addr i = [(addr, TBMQueue i)]

stateGetTBMQueue :: (Member (Embed IO) r, Member (State (RecvFromTBMQueues addr i)) r, Member Lock r, Eq addr) => addr -> Sem r (TBMQueue i)
stateGetTBMQueue addr = lock $ do
  s <- State.get
  case List.find (\(xAddr, _) -> xAddr == addr) s of
    Just (_, queue) -> pure queue
    Nothing -> do
      queue <- embed (newTBMQueueIO 1024)
      State.put ((addr, queue) : s)
      pure queue

interpretRecvFromTBMQueue :: (Member (Embed IO) r, Member Race r, Member Lock r, Eq addr) => InterpreterFor (RecvFrom addr i) r
interpretRecvFromTBMQueue = fmap snd . stateToIO [] . runScopedNew go . raiseUnder @(State _)
  where
    go addr m = do
      queue <- stateGetTBMQueue addr
      interpretQueueTBMWith queue m

inputToQueue :: (Member (Queue i) r) => InterpreterFor (InputWithEOF i) r
inputToQueue = interpret \case Input -> Queue.readMaybe
