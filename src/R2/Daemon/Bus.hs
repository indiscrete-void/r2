module R2.Daemon.Bus
  ( Chan (..),
    takeChan,
    putChan,
    Bus (..),
    busMakeChan,
    busTakeData,
    busPutData,
    busChan,
    NodeBusChan (..),
    NodeBus (..),
    NodeBusDir (..),
    nodeBusChan,
    nodeBusGetChan,
    nodeBusChanToIO,
    interpretBusTBM,
    ioToNodeBusChan,
    nodeBusMakeChan,
  )
where

import Control.Concurrent.STM.TBMQueue
import Control.Monad
import Control.Monad.Loops
import GHC.Conc.Sync
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Transport
import System.Timeout

data Chan d m a where
  TakeChan :: Chan d m (Maybe d)
  PutChan :: (Maybe d) -> Chan d m ()

makeSem ''Chan

inputToChan :: (Member (Chan d) r) => InterpreterFor (InputWithEOF d) r
inputToChan = runInputSem takeChan

outputToChan :: (Member (Chan d) r) => InterpreterFor (Output d) r
outputToChan = runOutputSem (putChan . Just)

closeToChan :: (Member (Chan d) r) => InterpreterFor Close r
closeToChan = runClose (putChan Nothing)

data Bus chan d m a where
  BusMakeChan :: Bus chan d m chan
  BusTakeData :: chan -> Bus chan d m (Maybe d)
  BusPutData :: chan -> Maybe d -> Bus chan d m ()

makeSem ''Bus

busChan :: (Member (Bus chan d) r) => chan -> InterpreterFor (Chan d) r
busChan chan = interpret \case
  TakeChan -> busTakeData chan
  PutChan d -> busPutData chan d

data NodeBusChan chan = NodeBusChan
  { nodeBusIn :: chan,
    nodeBusOut :: chan
  }
  deriving stock (Eq, Show)

ioToNodeBusChan ::
  (Member (Bus chan d) r) =>
  NodeBusChan chan ->
  InterpretersFor (Transport d d) r
ioToNodeBusChan NodeBusChan {..} =
  (busChan nodeBusOut . closeToChan . outputToChan . raise2Under @(Chan _))
    . (busChan nodeBusIn . inputToChan . raiseUnder @(Chan _))

data NodeBus addr chan d m a where
  NodeBusGetChan :: addr -> NodeBus addr chan d m (Maybe (NodeBusChan chan))

makeSem ''NodeBus

data NodeBusDir = FromWorld | ToWorld

nodeBusChan :: NodeBusDir -> NodeBusChan chan -> chan
nodeBusChan FromWorld NodeBusChan {..} = nodeBusIn
nodeBusChan ToWorld NodeBusChan {..} = nodeBusOut

nodeBusMakeChan :: (Member (Bus chan d) r) => Sem r (NodeBusChan chan)
nodeBusMakeChan = NodeBusChan <$> busMakeChan <*> busMakeChan

nodeBusChanToIO ::
  ( Members (Transport d d) r,
    Member (Bus chan d) r,
    Member Async r
  ) =>
  NodeBusChan chan ->
  Sem r ()
nodeBusChanToIO NodeBusChan {..} =
  sequenceConcurrently_
    [ busChan nodeBusIn $ whileJust_ input (busChan nodeBusIn . putChan . Just) >> putChan Nothing,
      busChan nodeBusOut $ whileJust_ takeChan output >> close
    ]

interpretBusTBM :: (Member (Embed IO) r) => Int -> Int -> InterpreterFor (Bus (TBMQueue d) d) r
interpretBusTBM bufferSize timeoutMS = interpret \case
  BusMakeChan -> embed $ newTBMQueueIO bufferSize
  BusTakeData chan ->
    let timeoutMicros = timeoutMS * 1000
     in join <$> embed (timeout timeoutMicros $ atomically $ readTBMQueue chan)
  BusPutData chan (Just d) -> embed $ atomically $ writeTBMQueue chan d
  BusPutData chan Nothing -> embed $ atomically $ closeTBMQueue chan
