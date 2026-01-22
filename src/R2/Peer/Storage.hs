module R2.Peer.Storage
  ( NodeState,
    Storage,
    Storages,
    storageToAtomicState,
    storageToIO,
    storageAddNode,
    storageRmNode,
    storageLookupNode,
    storageNodes,
    storageLockNode,
    nodesReaderToStorage,
    storagesToIO,
  )
where

import Control.Concurrent.STM.TBMQueue
import Data.ByteString (ByteString)
import Data.IORef
import Data.List qualified as List
import Data.Map qualified as Map
import Polysemy
import Polysemy.AtomicState
import Polysemy.Conc.Effect.Lock
import Polysemy.Internal.Tactics
import Polysemy.Reader
import Polysemy.Resource
import Polysemy.Scoped
import R2
import R2.Peer.Conn
import R2.Peer.Proto

type NodeState chan = [Node chan]

data Storage chan m a where
  StorageAddNode :: Node chan -> Storage chan m ()
  StorageRmNode :: Node chan -> Storage chan m ()
  StorageLookupNode :: Address -> Storage chan m (Maybe (Node chan))
  StorageNodes :: Storage chan m (NodeState chan)

makeSem ''Storage

storageLockNode :: (Member (Storage chan) r, Member Resource r) => Node chan -> Sem r c -> Sem r c
storageLockNode node = bracket_ (storageAddNode node) (storageRmNode node)

nodesReaderToStorage :: (Member (Storage chan) r) => InterpreterFor (Reader (NodeState chan)) r
nodesReaderToStorage = go id
  where
    go :: (Member (Storage chan) r) => (NodeState chan -> NodeState chan) -> InterpreterFor (Reader (NodeState chan)) r
    go f = interpretH \case
      Ask -> liftT $ f <$> storageNodes
      Local localF m -> do
        mm <- runT m
        raise $ go localF mm

storageToAtomicState :: (Member (AtomicState (NodeState chan)) r) => InterpreterFor (Storage chan) r
storageToAtomicState =
  interpret \case
    StorageAddNode node -> atomicModify' (node :)
    StorageRmNode node -> atomicModify' $ List.delete node
    StorageLookupNode addr -> List.find ((Just addr ==) . nodeAddr) <$> atomicGet
    StorageNodes -> atomicGet @(NodeState _)

storageToIO :: forall chan r. (Member (Embed IO) r) => InterpreterFor (Storage chan) r
storageToIO = fmap snd . atomicStateToIO ([] :: NodeState chan) . storageToAtomicState . raiseUnder

type Storages chan = Scoped Address (Storage chan)

storagesToIO ::
  (Member (Embed IO) r, Member Lock r) =>
  Sem (Storages (TBMQueue msg) ': r) a ->
  Sem r a
storagesToIO =
  fmap snd
    . atomicStateToIO Map.empty
    . runScopedNew @_ @(Storage _)
      ( \addr m -> do
          stateRef <- lock do
            stateMap <- atomicGet
            case Map.lookup addr stateMap of
              Just state -> pure state
              Nothing -> do
                initialState <- embed $ newIORef []
                atomicPut $ Map.insert addr initialState stateMap
                pure initialState
          runAtomicStateIORef stateRef $
            storageToAtomicState $
              raiseUnder @(AtomicState _) m
      )
    . raiseUnder
