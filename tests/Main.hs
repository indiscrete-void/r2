import Data.Serialize
import R2
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Address a deriving stock (Eq, Show)

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ testCase "r2 SendTo node0 (RouteTo node1 msg) = SendTo node1 (RoutedFrom node0 msg)" $
        r2 SendTo 0 (RouteTo 1 msg) @?= SendTo 1 (RoutedFrom 0 msg),
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
