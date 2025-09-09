module Polysemy.Transport.Bus (RecvFrom, RecvdFrom, SendTo, sendTo, recvFrom, outputToRecvdFrom, closeToRecvdFrom, interpretRecvFromTBMQueue) where

import Control.Concurrent.STM.TBMQueue
import Data.List qualified as List
import Polysemy
import Polysemy.AtomicState
import Polysemy.Conc (Race)
import Polysemy.Conc.Effect.Queue (Queue)
import Polysemy.Conc.Effect.Queue qualified as Effect.Queue
import Polysemy.Conc.Interpreter.Queue.TBM
import Polysemy.Conc.Queue qualified as Queue
import Polysemy.Input
import Polysemy.Output
import Polysemy.Scoped
import Polysemy.Transport

type RecvFrom addr i = Scoped addr (InputWithEOF i)

recvFrom :: (Member (RecvFrom addr i) r) => addr -> InterpreterFor (InputWithEOF i) r
recvFrom = scoped

type RecvdFrom addr i = (Output (addr, Maybe i))

outputToRecvdFrom :: (Member (RecvdFrom addr i) r) => addr -> InterpreterFor (Output i) r
outputToRecvdFrom addr = interpret \(Output i) -> output (addr, Just i)

closeToRecvdFrom :: (Member (RecvdFrom addr i) r) => addr -> InterpreterFor Close r
closeToRecvdFrom addr = interpret \Close -> output (addr, Nothing)

type SendTo addr o = Scoped addr (Output o)

sendTo :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
sendTo addr =
  scoped addr . reinterpret \case
    Output o -> do
      output o

type RecvFromTBMQueues addr i = [(addr, TBMQueue i)]

stateGetTBMQueue :: (Member (Embed IO) r, Member (AtomicState (RecvFromTBMQueues addr i)) r, Eq addr) => addr -> Sem r (TBMQueue i)
stateGetTBMQueue addr = do
  s <- atomicGet
  case List.find (\(xAddr, _) -> xAddr == addr) s of
    Just (_, queue) -> pure queue
    Nothing -> do
      queue <- embed (newTBMQueueIO 1024)
      atomicModify' ((addr, queue) :)
      pure queue

stateInterceptTBMQueueClose :: (Member (Queue i) r, Member (AtomicState (RecvFromTBMQueues addr i)) r, Eq addr) => addr -> Sem r a -> Sem r a
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
          atomicModify' $ List.filter (\(xAddr, _) -> xAddr /= addr)
          Queue.close
    )
    m

recvFromToQueue :: (Member (Scoped addr (Queue i)) r) => InterpreterFor (RecvFrom addr i) r
recvFromToQueue = runScopedNew \addr -> scoped addr . runInputSem Queue.readMaybe . raiseUnder

recvdFromToQueue :: (Member (Scoped addr (Queue i)) r) => InterpreterFor (RecvdFrom addr i) r
recvdFromToQueue = runOutputSem \(addr, o) -> scoped addr $ maybe Queue.close Queue.write o

runScopedQueueTBM :: (Member (Embed IO) r, Member Race r, Eq addr) => InterpreterFor (Scoped addr (Queue i)) r
runScopedQueueTBM = fmap snd . atomicStateToIO [] . go . raiseUnder @(AtomicState _)
  where
    go = runScopedNew \addr m -> do
      queue <- stateGetTBMQueue addr
      interpretQueueTBMWith queue $
        stateInterceptTBMQueueClose addr m

interpretRecvFromTBMQueue :: (Member (Embed IO) r, Member Race r, Eq addr) => InterpretersFor '[RecvFrom addr i, RecvdFrom addr i] r
interpretRecvFromTBMQueue = runScopedQueueTBM . recvdFromToQueue . recvFromToQueue . raise2Under
