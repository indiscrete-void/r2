import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "Unit Tests" []

main :: IO ()
main = defaultMain tests
