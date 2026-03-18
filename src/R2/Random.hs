module R2.Random where

import Control.Monad (replicateM)
import Data.Binary (Word8)
import Numeric (showHex)
import Polysemy
import R2
import System.Random (Uniform, initStdGen)
import System.Random.Stateful (StatefulGen, UniformRange (..), newIOGenM, uniformM)

cuteWordList :: [String]
cuteWordList =
  [ "smile",
    "happy",
    "sun",
    "star",
    "flower",
    "rainbow",
    "joy",
    "peace",
    "love",
    "dream",
    "hope",
    "kind",
    "sweet",
    "gentle",
    "warm",
    "cozy",
    "butterfly",
    "bunny",
    "kitten",
    "puppy",
    "sunshine",
    "blossom",
    "breeze",
    "cherry",
    "cloud",
    "cuddle",
    "daisy",
    "dolphin",
    "feather",
    "friendly",
    "garden",
    "giggle",
    "glow",
    "hamster",
    "heart",
    "honey",
    "hug",
    "mellow",
    "moon",
    "morning",
    "panda",
    "penguin",
    "petal",
    "puddle",
    "pumpkin",
    "rain",
    "ribbon",
    "snuggle",
    "sparkle",
    "sprinkle",
    "squirrel",
    "stitch",
    "sweater",
    "twinkle",
    "whisper",
    "wildflower"
  ]

showHexConstLen :: Word8 -> String
showHexConstLen b =
  let hex = showHex b ""
   in if length hex == 1 then '0' : hex else hex

randomCuteWord :: (StatefulGen g m) => g -> m String
randomCuteWord g = do
  idx <- uniformRM (0, length cuteWordList - 1) g
  return $ cuteWordList !! idx

randomHex8 :: (StatefulGen g m) => g -> m String
randomHex8 g = do
  bytes <- replicateM 8 (uniformRM (0, 255) g)
  return $ concatMap showHexConstLen bytes

-- | generates `cuteword-16hex`
randomCuteId :: (StatefulGen g m) => g -> m String
randomCuteId g = do
  word <- randomCuteWord g
  hex <- randomHex8 g
  return $ word ++ "-" ++ hex

instance Uniform LabelAddr where
  uniformM = fmap LabelAddr . randomCuteId

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

childAddr :: (Member Random r) => String -> Sem r NameAddr
childAddr tag = do
  addr <- labelAddr <$> uniformlyRandom
  pure $ NameTagAddr (TagAddr tag addr)
