import Polysemy.Async
import Polysemy.Close
import Polysemy.Final
import Polysemy.Input
import Polysemy.Output
import Polysemy.Process (scopedProcToIOFinal)
import Polysemy.Trace
import R2
import R2.Peer
import R2.Peer.Daemon
import Test.Tasty
import Test.Tasty.HUnit

data SendTo a = SendTo Address a deriving stock (Eq, Show)

testR2 :: TestTree
testR2 =
  testGroup
    "r2"
    [ testCase "r2 SendTo node0 (RouteTo node1 msg) = SendTo node1 (RoutedFrom node0 msg)" $
        r2 SendTo 0 (RouteTo 1 msg) @?= SendTo 1 (RoutedFrom 0 msg)
    ]
  where
    msg = Just ()

testTunnel :: TestTree
testTunnel =
  testGroup
    "tunnel"
    [ testCase "r2d: tunnelProcess" do
        let input = [MsgData $ Just $ Raw "a\n"]
        (output, _) <-
          runFinal . asyncToIOFinal . embedToFinal . ignoreTrace . scopedProcToIOFinal 8192 . runClose . runInputList input . outputToIOMonoidAssocR pure $
            tunnelProcess "cat"
        output @?= input <> [MsgData Nothing]
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2, testTunnel]

main :: IO ()
main = defaultMain tests
