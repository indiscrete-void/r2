module R2.Daemon.Storage
  ( NodeState,
    Storage,
    storageToIO,
    storageAddNode,
    storageRmNode,
    storageLookupNode,
    storageNodes,
    storageLockNode,
    nodesReaderToStorage,
  )
where

import Data.List qualified as List
import Polysemy
import Polysemy.AtomicState
import Polysemy.Internal.Tactics
import Polysemy.Reader
import Polysemy.Resource
import R2
import R2.Daemon.Node

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

storageToIO :: forall chan r. (Member (Embed IO) r) => InterpreterFor (Storage chan) r
storageToIO =
  fmap snd . atomicStateToIO ([] :: NodeState chan) . reinterpret \case
    StorageAddNode node -> atomicModify' (node :)
    StorageRmNode node -> atomicModify' $ List.delete node
    StorageLookupNode addr -> List.find ((Just addr ==) . nodeAddr) <$> atomicGet
    StorageNodes -> atomicGet @(NodeState _)
