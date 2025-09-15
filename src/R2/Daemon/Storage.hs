module R2.Daemon.Storage (State, Storage, initialState, stateAddNode, stateDeleteNode, stateLookupNode, stateReflectNode, runStorage) where

import Data.List qualified as List
import Polysemy
import Polysemy.AtomicState
import Polysemy.Resource
import Polysemy.Trace
import R2
import R2.Daemon
import Text.Printf qualified as Text

type State chan = [Connection chan]

type Storage chan = AtomicState (State chan)

initialState :: State s
initialState = []

withReverse :: ([a] -> [b]) -> [a] -> [b]
withReverse f = reverse . f . reverse

stateAddNode :: (Member (AtomicState (State q)) r) => Connection q -> Sem r ()
stateAddNode nodeData = atomicModify' $ withReverse (nodeData :)

stateDeleteNode :: (Member (AtomicState (State q)) r) => Connection q -> Sem r ()
stateDeleteNode node = atomicModify' $ withReverse (List.filter (\xNode -> connAddr xNode == connAddr node))

stateLookupNode :: (Member (AtomicState (State q)) r) => Address -> Sem r (Maybe (Connection q))
stateLookupNode addr = List.find ((addr ==) . connAddr) <$> atomicGet

stateReflectNode :: (Member (AtomicState (State q)) r, Member Trace r, Member Resource r) => Connection q -> Sem r c -> Sem r c
stateReflectNode node = bracket_ addNode delNode
  where
    addNode = trace (Text.printf "storing %s" $ show $ connAddr node) >> stateAddNode node
    delNode = trace (Text.printf "forgetting %s" $ show $ connAddr node) >> stateDeleteNode node

runStorage :: (Member (Embed IO) r) => InterpreterFor (Storage chan) r
runStorage = fmap snd . atomicStateToIO initialState
