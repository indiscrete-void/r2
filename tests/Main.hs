import Control.Arrow
import Polysemy
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Close
import Polysemy.Conc
import Polysemy.Input
import Polysemy.Output
import Polysemy.Process (Process, scopedProcToIOFinal)
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport.Bus
import R2
import R2.Peer
import R2.Peer.Daemon
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

sendToToState :: (Member (Embed IO) r) => Sem (Polysemy.Transport.Bus.SendTo Address Message ': r) a -> Sem r ([Message], a)
sendToToState =
  fmap (first reverse)
    . atomicStateToIO []
    . ( runScopedNew \_ -> runOutputSem (\o -> atomicModify' (o :))
      )
    . raiseUnder @(AtomicState [Message])

runTunnelTest :: Sem '[Scoped CreateProcess Process, Race, Trace, Embed IO, Async, Final IO] ([Message], a) -> IO [Message]
runTunnelTest = fmap fst . runFinal . asyncToIOFinal . embedToFinal @IO . ignoreTrace . interpretRace . scopedProcToIOFinal 8192

catTestCase :: String -> ([Message] -> IO [Message]) -> TestTree
catTestCase name m = testCase name do
  let input = [MsgData $ Just $ Raw "a\n"]
  output <- m input
  output @?= input <> [MsgData Nothing]

testR2D :: TestTree
testR2D =
  testGroup
    "r2d"
    [ catTestCase "tunnelProcess" \input ->
        runTunnelTest . runClose . runInputList input . outputToIOMonoidAssocR pure $ do
          tunnelProcess "cat",
      catTestCase "routed tunnelProcess" \input ->
        runTunnelTest . sendToToState . interpretRecvFromTBMQueue $ do
          mapM_ (recvdFrom defaultAddr) input
          ioToBus defaultAddr $ do
            tunnelProcess "cat"
    ]

tests :: TestTree
tests = testGroup "Unit Tests" [testR2, testR2D]

main :: IO ()
main = defaultMain tests
