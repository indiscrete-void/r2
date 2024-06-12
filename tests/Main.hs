import Control.Monad
import Control.Monad.Extra
import Pnet.Routing
import Polysemy.Async
import Polysemy.Conc
import Polysemy.Conc.Input
import Polysemy.Final
import Polysemy.Input
import Polysemy.Output
import Polysemy.Resource
import Polysemy.State
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Node a deriving stock (Eq, Show)

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ let msg = Just "hello, world!"
       in testCase "r2 SendTo node0 (RouteTo nb msg) = SendTo node1 (RoutedFrom na msg)" $
            r2 SendTo 0 (RouteTo 1 msg) @?= SendTo 1 (RoutedFrom 0 msg)
    ]

testConcInput :: TestTree
testConcInput =
  testGroup
    "Concurrent Input"
    [ let in' = [0 .. 128] :: [Int]
          out = map Just in' <> [Nothing]
          run = runFinal @IO . asyncToIOFinal . resourceToIOFinal . interpretRace . interpretMaskFinal . embedToFinal @IO . evalState [] . interpretLockReentrant
          runChild = evalState @Int 0 . runInputList in' . (fmap fst . runOutputList)
          go = whileJustM (inputConc >>= \i -> output i >> pure (void i))
       in testCase "inputConc" . run $ do
            threads <- replicateM 128 . async $ do
              actualOut <- runChild go
              embedFinal @IO $ actualOut @?= out
            mapM_ await threads
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2, testConcInput]

main :: IO ()
main = defaultMain tests
