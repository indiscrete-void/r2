import Control.Monad
import Data.ByteString.Char8 qualified as BC
import Network.Socket (bind, listen)
import Network.Socket qualified as Network
import Pnet
import Pnet.Polysemy.Trace
import Polysemy hiding (run, send)
import Polysemy.Socket
import Polysemy.Trace

pnetd :: forall s r. (Member Trace r, Member (Socket s) r) => Sem r ()
pnetd = forever $ accept @s >>= echo
  where
    echo sock = do
      msg <- receive sock
      traceTagged "client -> server" (BC.unpack msg)
      send sock msg
      traceTagged "server -> client" (BC.unpack msg)
      close sock

main :: IO ()
main =
  let run sock = runM . socketToIO bufferSize sock . traceToStdout
   in withPnetSocket \sock -> do
        addr <- pnetSocketAddr
        bind sock addr
        listen sock 5
        run sock $ pnetd @Network.Socket
