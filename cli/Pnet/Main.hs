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

pnet :: (Member (InputWithEOF RouteTo) r, Member (Output RoutedFrom) r, Member ByteInputWithEOF r, Member ByteOutput r, Member (InputWithEOF Response) r, Member (Output Request) r, Member Fail r, Member Trace r, Member Close r, Member Async r) => Command -> Sem r ()
pnet Ls = output ListNodes >> (inputOrFail @Response >>= traceTagged "Ls" . show)
pnet (Connect transport maybeAddress) = do
  output (ConnectNode transport maybeAddress)
  case transport of
    Stdio -> async_ (handle nodeToIO) >> handle ioToNode
      where
        ioToNode msg = traceTagged ("RoutedFrom " <> show defaultAddr) (show msg) >> output (RoutedFrom defaultAddr $ Just msg)
        nodeToIO (RouteTo address maybeMsg)
          | address == defaultAddr = traceTagged ("RouteTo " <> show address) (show maybeMsg) >> maybe close output maybeMsg
          | otherwise = _
    _ -> _
pnet _ = _

main :: IO ()
main =
  let runUnserialized = runDecoder . deserializeInput @Response . serializeOutput @Request . deserializeInput @RouteTo . serializeOutput @RoutedFrom
      runTransport s = inputToSocket bufferSize s . outputToSocket s . runUnserialized
      runStdio = outputToIO stdout . inputToIO bufferSize stdin . closeToIO stdout
      run s = runFinal . asyncToIOFinal . embedToFinal @IO . failToEmbed @IO . traceToStderrBuffered . runTransport s . runStdio
   in withPnetSocket \s -> do
        (Options command maybeSocketPath) <- parse
        connect s =<< pnetSocketAddr maybeSocketPath
        run s $ pnet command
