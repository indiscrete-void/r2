import Control.Concurrent (takeMVar)
import R2.DSL (runManagedDaemon)
import R2.Manager.Options (parse)

main :: IO ()
main = parse >>= runManagedDaemon >>= takeMVar
