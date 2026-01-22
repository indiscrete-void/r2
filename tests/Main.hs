import R2
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Address a deriving stock (Eq, Show)

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ testCase "r2 SendTo node0 (RouteTo node1 msg) = SendTo node1 (RoutedFrom node0 msg)" $
        let node0 = "node0"
            node1 = "node1"
         in r2 SendTo node0 (RouteTo node1 msg) @?= SendTo node1 (RoutedFrom node0 msg)
    ]
  where
    msg = Just ()

tests :: TestTree
tests = testGroup "Unit Tests" [testR2]

main :: IO ()
main = defaultMain tests
