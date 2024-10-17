import Control.Monad
import Control.Monad.Extra
import Data.List qualified as List
import Data.Maybe
import Data.Serialize
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.Conc
import Polysemy.Conc.Input
import Polysemy.Extra.Trace
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
      let runTest i = runM . traceToStderrBuffered . runClose . runOutput . runInput i . runR2 defaultAddr
       in testCase "runR2 node cat `feed` RoutedFrom node msg = RouteTo node msg" $
            runTest (RoutedFrom defaultAddr msg) (input >>= output . fromJust) >>= assertEqual "" (RouteTo defaultAddr msg),
      let runTest = runM . traceToStderrBuffered . runOutput
       in testCase "runR2 node close = RouteTo node Nothing" $
            runTest (runR2Close defaultAddr close) >>= assertEqual "" (RouteTo defaultAddr (Nothing :: Maybe ())),
      testCase "encode (RouteTo node (encode msg)) = encode (RouteTo node msg)" $
        encode (RouteTo defaultAddr (encode msg)) @?= encode (RouteTo defaultAddr msg),
      testCase "encode (RoutedFrom node (encode msg)) = encode (RoutedFrom node msg)" $
        encode (RoutedFrom defaultAddr (encode msg)) @?= encode (RoutedFrom defaultAddr msg)
    ]
  where
    msg = Just ()

tests :: TestTree
tests = testGroup "Unit Tests" [testR2]

main :: IO ()
main = defaultMain tests
