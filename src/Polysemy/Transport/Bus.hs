module Polysemy.Transport.Bus (RecvFrom, SendTo, sendTo, recvdFrom, recvFrom, interpretRecvFromTBMQueue, inputToQueue) where

import Control.Concurrent.STM.TBMQueue
import Data.List qualified as List
import Polysemy
import Polysemy.Conc (Race)
import Polysemy.Conc.Effect.Queue (Queue)
import Polysemy.Conc.Effect.Queue qualified as Effect.Queue
import Polysemy.Conc.Interpreter.Queue.TBM
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

stateGetTBMQueue :: (Member (Embed IO) r, Member (State (RecvFromTBMQueues addr i)) r, Eq addr) => addr -> Sem r (TBMQueue i)
stateGetTBMQueue addr = do
  s <- State.get
  case List.find (\(xAddr, _) -> xAddr == addr) s of
    Just (_, queue) -> pure queue
    Nothing -> do
      queue <- embed (newTBMQueueIO 1024)
      State.put ((addr, queue) : s)
      pure queue

stateInterceptTBMQueueClose :: (Member (Queue i) r, Member (State (RecvFromTBMQueues addr i)) r, Eq addr) => addr -> Sem r a -> Sem r a
stateInterceptTBMQueueClose addr m = do
  intercept @(Queue _)
    ( \case
        Effect.Queue.Read -> Queue.read
        Effect.Queue.TryRead -> Queue.tryRead
        Effect.Queue.ReadTimeout t -> Queue.readTimeout t
        Effect.Queue.Peek -> Queue.peek
        Effect.Queue.TryPeek -> Queue.tryPeek
        Effect.Queue.Write x -> Queue.write x
        Effect.Queue.TryWrite x -> Queue.tryWrite x
        Effect.Queue.WriteTimeout t x -> Queue.writeTimeout t x
        Effect.Queue.Closed -> Queue.closed
        Effect.Queue.Close -> do
          State.modify $ List.filter (\(xAddr, _) -> xAddr /= addr)
          Queue.close
    )
    m

interpretRecvFromTBMQueue :: (Member (Embed IO) r, Member Race r, Eq addr) => InterpreterFor (RecvFrom addr i) r
interpretRecvFromTBMQueue = fmap snd . stateToIO [] . runScopedNew go . raiseUnder @(State _)
  where
    go addr m = do
      queue <- stateGetTBMQueue addr
      interpretQueueTBMWith queue . stateInterceptTBMQueueClose addr $ m

inputToQueue :: (Member (Queue i) r) => InterpreterFor (InputWithEOF i) r
inputToQueue = interpret \case Input -> Queue.readMaybe
