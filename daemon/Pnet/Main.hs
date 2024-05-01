import Control.Monad
import Data.ByteString.Char8 qualified as BC
import Network.Socket (bind, listen)
import Network.Socket qualified as Network
import Pnet
import Pnet.Polysemy.Trace
import Polysemy hiding (run, send)
import Polysemy.Fail
import Polysemy.Input
import Polysemy.Output
import Polysemy.Socket
import Polysemy.Trace

pnetd :: forall s r. (Member Trace r, Member (Socket s) r, Member Fail r) => Sem r ()
pnetd = forever $ accept @s >>= process
  where
    process sock = transportToSocket sock (processT sock)
    processT sock = do
      (Just msg) <- input
      traceTagged "client -> server" (BC.unpack msg)
      output msg
      traceTagged "server -> client" (BC.unpack msg)
      close sock

main :: IO ()
main =
  let run sock = runM . socketToIO bufferSize sock . traceToStdout . failToEmbed @IO
   in withPnetSocket \sock -> do
        addr <- pnetSocketAddr
        bind sock addr
        listen sock 5
        run sock $ pnetd @Network.Socket
