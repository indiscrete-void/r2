module R2.Daemon.Storage (NodeState, Storage, storageToIO, storageAddNode, storageRmNode, storageLookupNode, storageNodes, storageLockNode, nodesReaderToStorage) where

import Data.Map (Map)
import Data.Map qualified as Map
import Polysemy
import Polysemy.AtomicState
import Polysemy.Internal.Tactics
import Polysemy.Reader
import Polysemy.Resource
import Polysemy.Trace
import R2
import R2.Daemon
import Text.Printf qualified as Text

type NodeState chan = Map Address (Connection chan)

data Storage chan m a where
  StorageAddNode :: Connection chan -> Storage chan m ()
  StorageRmNode :: Connection chan -> Storage chan m ()
  StorageLookupNode :: Address -> Storage chan m (Maybe (Connection chan))
  StorageNodes :: Storage chan m (NodeState chan)

makeSem ''Storage

storageLockNode :: (Member (Storage chan) r, Member Trace r, Member Resource r) => Connection chan -> Sem r c -> Sem r c
storageLockNode node@Connection {..} = bracket_ addNode delNode
  where
    addNode = trace (Text.printf "storing %s" $ show connAddr) >> storageAddNode node
    delNode = trace (Text.printf "forgetting %s" $ show connAddr) >> storageRmNode node

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
  fmap snd . atomicStateToIO (Map.empty :: NodeState chan) . reinterpret \case
    StorageAddNode conn@Connection {connAddr} -> atomicModify' $ Map.insert connAddr conn
    StorageRmNode Connection {connAddr} -> atomicModify' $ Map.delete connAddr
    StorageLookupNode connAddr -> Map.lookup connAddr <$> atomicGet
    StorageNodes -> atomicGet @(NodeState _)
