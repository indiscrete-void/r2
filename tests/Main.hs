import Control.Monad
import Control.Monad.Extra
import Data.List qualified as List
import Data.Maybe
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.Conc
import Polysemy.Conc.Input
import Polysemy.Resource
import Polysemy.State
import Polysemy.Transport
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Address a deriving stock (Eq, Show)

runInput :: i -> InterpreterFor (InputWithEOF i) r
runInput = runInputList . List.singleton

runOutput :: Sem (Output o ': r) a -> Sem r o
runOutput = fmap (head . fst) . runOutputList

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ testCase "r2 SendTo node0 (RouteTo node1 msg) = SendTo node1 (RoutedFrom node0 msg)" $
        r2 SendTo 0 (RouteTo 1 msg) @?= SendTo 1 (RoutedFrom 0 msg),
      let runTest i = run . runOutput . runInput i . runR2 node
       in testCase "runR2 node cat `feed` RoutedFrom node msg == RouteTo node msg" $
            runTest (RoutedFrom node msg) (input >>= output . fromJust) @?= RouteTo node msg,
      let runTest = run . runOutput . runInputList []
       in testCase "runR2 node close == RouteTo node Nothing" $
            runTest (runR2 node close) @?= RouteTo node Nothing
    ]
  where
    msg = Just "hello, world!"
    node = 0

testConcInput :: TestTree
testConcInput =
  testGroup
    "Concurrent Input"
    [ let in' = [0 .. 128] :: [Int]
          out = map Just in' <> [Nothing]
          runTest = runFinal @IO . asyncToIOFinal . resourceToIOFinal . interpretRace . interpretMaskFinal . embedToFinal @IO . evalState [] . interpretLockReentrant
          runChild = evalState @Int 0 . runInputList in' . (fmap fst . runOutputList)
          go = whileJustM (inputConc >>= \i -> output i >> pure (void i))
       in testCase "inputConc" . runTest $ do
            threads <- replicateM 128 . async $ do
              actualOut <- runChild go
              embedFinal @IO $ actualOut @?= out
            mapM_ await threads
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2, testConcInput]

main :: IO ()
main = defaultMain tests
