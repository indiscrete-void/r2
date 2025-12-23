module R2.Random where

import Polysemy
import R2
import System.Random (Uniform, initStdGen)
import System.Random.Stateful (newIOGenM, uniformM)
import Text.Printf (printf)

data Random m a where
  UniformlyRandom :: forall a m. (Uniform a) => Random m a

uniformlyRandom :: (Uniform a, Member Random r) => Sem r a
uniformlyRandom = send UniformlyRandom

randomToIO :: (Member (Embed IO) r) => InterpreterFor Random r
randomToIO m = do
  stdGen <- embed $ initStdGen >>= newIOGenM
  go stdGen m
  where
    go stdGen = interpret \case
      UniformlyRandom -> embed $ uniformM stdGen

childAddr :: (Member Random r, Show a) => a -> Sem r Address
childAddr server = do
  addr <- uniformlyRandom @Address
  pure $ Addr $ printf "%s/child/%s" (show server) (show addr)
