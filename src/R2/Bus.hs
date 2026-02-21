module R2.Bus
  ( Chan (..),
    takeChan,
    putChan,
    Bus (..),
    busMakeChan,
    busTakeData,
    busPutData,
    busChan,
    Inbound (..),
    Outbound (..),
    Bidirectional (..),
    chanToIO,
    interpretBusTBM,
    inputToChan,
    outputToChan,
    inputToBusChan,
    outputToBusChan,
    ioToChan,
    makeBidirectionalChan,
    linkChansOneWay,
    linkChansBidirectional,
  )
where

import Control.Concurrent.STM.TBMQueue
import Control.Monad.Extra
import Control.Monad.Loops
import GHC.Conc.Sync
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Transport

data Chan d m a where
  TakeChan :: Chan d m (Maybe d)
  PutChan :: (Maybe d) -> Chan d m ()

makeSem ''Chan

inputToChan :: (Member (Chan d) r) => InterpreterFor (InputWithEOF d) r
inputToChan = runInputSem takeChan

outputToChan :: (Member (Chan d) r) => InterpreterFor (OutputWithEOF d) r
outputToChan = runOutputSem putChan

data Bus chan d m a where
  BusMakeChan :: Bus chan d m chan
  BusTakeData :: chan -> Bus chan d m (Maybe d)
  BusPutData :: chan -> Maybe d -> Bus chan d m ()

makeSem ''Bus

busChan :: (Member (Bus chan d) r) => chan -> InterpreterFor (Chan d) r
busChan chan = interpret \case
  TakeChan -> busTakeData chan
  PutChan d -> busPutData chan d

newtype Inbound chan = Inbound chan

newtype Outbound chan = Outbound chan

data Bidirectional chan = Bidirectional
  { inboundChan :: chan,
    outboundChan :: chan
  }
  deriving stock (Eq, Show)

makeBidirectionalChan :: (Member (Bus chan d) r) => Sem r (Bidirectional chan)
makeBidirectionalChan = Bidirectional <$> busMakeChan <*> busMakeChan

inputToBusChan :: (Member (Bus chan d) r) => chan -> Sem (InputWithEOF d ': r) a -> Sem r a
inputToBusChan chan = busChan chan . inputToChan . raiseUnder @(Chan _)

outputToBusChan :: (Member (Bus chan d) r) => chan -> Sem (OutputWithEOF d ': r) a -> Sem r a
outputToBusChan chan = busChan chan . outputToChan . raiseUnder @(Chan _)

ioToChan ::
  (Member (Bus chan d) r) =>
  Bidirectional chan ->
  InterpretersFor (Transport d d) r
ioToChan Bidirectional {..} =
  outputToBusChan outboundChan
    . inputToBusChan inboundChan

drainMaybeM :: (Monad m) => m (Maybe a) -> (Maybe a -> m b) -> m b
drainMaybeM m f =
  m >>= \case
    ma@(Just _) -> f ma >> drainMaybeM m f
    Nothing -> f Nothing

chanToIO ::
  ( Members (Transport d d) r,
    Member (Bus chan d) r,
    Member Async r
  ) =>
  Bidirectional chan ->
  Sem r ()
chanToIO Bidirectional {..} =
  sequenceConcurrently_
    [ busChan inboundChan $ drainMaybeM input putChan,
      busChan outboundChan $ drainMaybeM takeChan output
    ]

linkChansOneWay :: (Member (Bus chan d) r) => chan -> chan -> Sem r ()
linkChansOneWay inboundChan outboundChan = do
  d <- busChan outboundChan takeChan
  busChan inboundChan $ putChan d
  whenJust d $ const (linkChansOneWay inboundChan outboundChan)

linkChansBidirectional :: (Member (Bus chan d) r, Member Async r) => Bidirectional chan -> Bidirectional chan -> Sem r ()
linkChansBidirectional
  Bidirectional {inboundChan = inboundA, outboundChan = outboundA}
  Bidirectional {inboundChan = inboundB, outboundChan = outboundB} = do
    sequenceConcurrently_
      [ linkChansOneWay inboundA outboundB,
        linkChansOneWay inboundB outboundA
      ]

interpretBusTBM :: forall d r. (Member (Embed IO) r) => Int -> InterpreterFor (Bus (TBMQueue d) d) r
interpretBusTBM bufferSize = interpret \case
  BusMakeChan -> embed $ newTBMQueueIO bufferSize
  BusTakeData chan -> embed (atomically $ readTBMQueue chan)
  BusPutData chan (Just d) -> embed $ atomically $ writeTBMQueue chan d
  BusPutData chan Nothing -> embed $ atomically $ closeTBMQueue chan
