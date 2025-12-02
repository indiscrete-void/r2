import Polysemy
import Polysemy.Async
import Polysemy.Close
import Polysemy.Conc
import Polysemy.Input
import Polysemy.Output
import Polysemy.Process (Process, scopedProcToIOFinal)
import Polysemy.Scoped
import Polysemy.Trace
import R2
import R2.Daemon.Handler
import R2.Peer
import System.Process.Extra (CreateProcess)
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

runTunnelTest :: Sem '[Scoped CreateProcess Process, Race, Trace, Embed IO, Async, Final IO] ([Message], a) -> IO [Message]
runTunnelTest = fmap fst . runFinal . asyncToIOFinal . embedToFinal @IO . ignoreTrace . interpretRace . scopedProcToIOFinal 8192

testCat :: String -> ([Message] -> IO [Message]) -> TestTree
testCat name m = testCase name do
  let input = [MsgData $ Just $ Raw "a\n"]
  output <- m input
  output @?= input <> [MsgData Nothing]

testR2D :: TestTree
testR2D =
  testGroup
    "r2d"
    [ testCat "`tunnelProcess \"cat\"` echoes back" \input ->
        runTunnelTest . runInputList input . outputToIOMonoidAssocR pure . runClose mempty $ do
          tunnelProcess "cat"
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2, testR2D]

main :: IO ()
main = defaultMain tests
