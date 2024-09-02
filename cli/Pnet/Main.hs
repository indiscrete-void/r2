import Control.Monad.Extra
import Data.ByteString (ByteString)
import Network.Socket hiding (close)
import Pnet
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run)
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import System.IO

pnet :: (Members (TransportEffects (RouteTo (Maybe ByteString)) (RoutedFrom (Maybe ByteString))) r, Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF Response) r, Member (Output Handshake) r, Member Fail r, Member Trace r, Member Close r, Member Async r) => Command -> Sem r ()
pnet Ls = output ListNodes >> (inputOrFail @Response >>= traceTagged "Ls" . show)
pnet (Connect transport maybeAddress) = do
  output (ConnectNode transport maybeAddress)
  case transport of
    Stdio -> async_ nodeToIO >> ioToNode
      where
        ioToNode = whenJustM input (exposeR2 defaultAddr . output)
        nodeToIO = whenJustM (exposeR2 defaultAddr input) output
    _ -> _
pnet _ = _

main :: IO ()
main =
  let runUnserialized = runDecoder . deserializeInput @Response . serializeOutput @Handshake . deserializeInput @(RouteTo (Maybe ByteString)) . serializeOutput @(RoutedFrom (Maybe ByteString))
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      run s = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport s . runStdio
   in withPnetSocket \s -> do
        (Options command maybeSocketPath) <- parse
        connect s =<< pnetSocketAddr maybeSocketPath
        run s $ pnet command
