module Polysemy.Transport.Bus (RecvdFrom (..), AddRecvFrom, RecvFrom, SendTo, sendTo, recvdFrom, recvFrom, interpretRecvFromTBMQueue, interpretRecvdFromTBMQueue, interpretTBMQueueStateIO) where

import Control.Concurrent.STM.TBMQueue
import Data.List qualified as List
import Polysemy
import Polysemy.Conc (Race)
import Polysemy.Conc.Effect.Lock
import Polysemy.Conc.Interpreter.Queue.TBM
import Polysemy.Conc.Queue qualified as Queue
import Polysemy.Input
import Polysemy.Output
import Polysemy.Scoped
import Polysemy.State
import Polysemy.State qualified as State

data RecvdFrom addr i = RecvdFrom addr i

type AddRecvFrom addr i = Output (RecvdFrom addr i)

type RecvFrom addr i = Scoped addr (Input i)

type SendTo addr o = Scoped addr (Output o)

sendTo :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
sendTo = scoped

recvdFrom :: (Member (Output (RecvdFrom addr i)) r) => addr -> i -> Sem r ()
recvdFrom addr i = output $ RecvdFrom addr i

recvFrom :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
recvFrom = scoped

type RecvFromTBMQueues addr i = [(addr, TBMQueue i)]

stateGetTBMQueue :: (Member (State (RecvFromTBMQueues addr i)) r, Member (Embed IO) r, Eq addr, Member Lock r) => addr -> Sem r (TBMQueue i)
stateGetTBMQueue addr = lock $ do
  s <- State.get
  case List.find (\(xAddr, _) -> xAddr == addr) s of
    Just (_, queue) -> pure queue
    Nothing -> do
      queue <- embed (newTBMQueueIO 1024)
      State.put ((addr, queue) : s)
      pure queue

interpretRecvFromTBMQueue :: (Member (State (RecvFromTBMQueues addr i)) r, Member (Embed IO) r, Member Race r, Eq addr, Member Lock r) => InterpreterFor (RecvFrom addr (Maybe i)) r
interpretRecvFromTBMQueue = runScopedNew \addr -> interpret @(Input _) \case
  Input -> do
    queue <- stateGetTBMQueue addr
    interpretQueueTBMWith queue Queue.readMaybe

interpretRecvdFromTBMQueue :: (Member (State (RecvFromTBMQueues addr i)) r, Member (Embed IO) r, Member Race r, Eq addr, Member Lock r) => InterpreterFor (AddRecvFrom addr (Maybe i)) r
interpretRecvdFromTBMQueue = interpret @(AddRecvFrom _ _) \case
  Output (RecvdFrom addr i) -> do
    queue <- stateGetTBMQueue addr
    interpretQueueTBMWith queue $ maybe Queue.close Queue.write i

interpretTBMQueueStateIO :: (Member (Embed IO) r) => InterpreterFor (State (RecvFromTBMQueues addr i)) r
interpretTBMQueueStateIO = fmap snd . stateToIO []
