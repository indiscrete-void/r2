import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket (bind, listen)
import Pnet
import Pnet.Daemon
import Pnet.Daemon.Server
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run, send)
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Socket.Accept
import Polysemy.Transport
import System.Exit
import System.Posix

main :: IO ()
main =
  let runUnserialized :: (Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r) => InterpretersFor (InputWithEOF Handshake ': Output Response ': '[]) r
      runUnserialized = serializeOutput @Response . deserializeInput @Handshake
      runUnserialized' :: (Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe ByteString)) ': Output (RouteTo (Maybe ByteString)) ': '[]) r
      runUnserialized' = serializeOutput @(RouteTo (Maybe ByteString)) . deserializeInput @(RoutedFrom (Maybe ByteString))
      runTransport f s = closeToSocket timeout s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s = acceptToIO s . runScopedBundle @(TransportEffects Handshake Response) (runTransport runUnserialized) . runScopedBundle @(TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) (runTransport runUnserialized')
      runAtomicState = void . atomicStateToIO initialState
      run s =
        runFinal @IO
          . asyncToIOFinal
          . runDecoder
          . embedToFinal @IO
          . failToEmbed @IO
          . traceToStdoutBuffered
          . runSocket s
          . runAtomicState
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withPnetSocket \s -> do
        (Options maybeSocketPath daemon) <- parse
        addr <- pnetSocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon $ run s pnetd
