import Control.Monad
import Data.ByteString.Char8 qualified as BC
import Network.Socket (bind, listen)
import Pnet
import Pnet.Polysemy.Trace
import Polysemy hiding (run, send)
import Polysemy.Fail
import Polysemy.Scoped
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport

pnetd :: forall r. (Member Trace r, Member (Scoped_ Socket) r, Member Fail r) => Sem r ()
pnetd = forever . accept $ do
  (Just msg) <- input
  traceTagged "client -> server" (BC.unpack msg)
  output msg
  traceTagged "server -> client" (BC.unpack msg)
  close

main :: IO ()
main =
  let run server = runM . scopedSockToIO bufferSize server . traceToStdout . failToEmbed @IO
   in withPnetSocket \sock -> do
        addr <- pnetSocketAddr
        bind sock addr
        listen sock 5
        run sock pnetd
