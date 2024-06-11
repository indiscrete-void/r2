import Pnet.Routing
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Node a deriving stock (Eq, Show)

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ let msg = Just "hello, world!"
       in testCase "handleR2 SendTo n1 (RouteTo n2 msg) = SendTo n2 (RoutedFrom n1 msg)" $
            handleR2 SendTo 0 (RouteTo 1 msg) @?= SendTo 1 (RoutedFrom 0 msg)
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2]

main :: IO ()
main = defaultMain tests
