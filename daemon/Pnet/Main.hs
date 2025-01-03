import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket (bind, listen)
import Pnet
import Pnet.Daemon
import Pnet.Options
import Pnet.Routing
import Polysemy hiding (run, send)
import Polysemy.Any
import Polysemy.Async
import Polysemy.AtomicState
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Resource
import Polysemy.ScopedBundle
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Socket.Accept
import Polysemy.Trace
import Polysemy.Transport
import System.Exit
import System.Posix

main :: IO ()
main =
  let runUnserialized :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF Handshake ': Output Response ': '[]) r
      runUnserialized = serializeOutput . deserializeInput
      runUnserialized' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RouteTo ByteString) ': Output (RoutedFrom ByteString) ': '[]) r
      runUnserialized' = serializeOutput . deserializeInput
      runUnserialized'' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe (RoutedFrom Connection))) ': Output (RouteTo (Maybe (RouteTo Connection))) ': '[]) r
      runUnserialized'' = serializeOutput . deserializeInput
      runUnserialized''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))))) ': Output (RouteTo (Maybe (RouteTo (Maybe (RouteTo (Maybe ByteString)))))) ': '[]) r
      runUnserialized''' = serializeOutput . deserializeInput
      runUnserialized'''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) ': Output (RouteTo (Maybe (RouteTo (Maybe ByteString)))) ': '[]) r
      runUnserialized'''' = serializeOutput . deserializeInput
      runUnserialized''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RouteTo (Maybe (RouteTo (Maybe ByteString)))) ': Output (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) ': '[]) r
      runUnserialized''''' = serializeOutput . deserializeInput
      runUnserialized'''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))) ': Output (RouteTo (Maybe (RouteTo (Maybe Handshake)))) ': '[]) r
      runUnserialized'''''' = serializeOutput . deserializeInput
      runUnserialized''''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe (RouteTo ByteString))) ': Output (RouteTo (Maybe (RoutedFrom ByteString))) ': '[]) r
      runUnserialized''''''' = serializeOutput . deserializeInput
      runUnserialized'''''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe ByteString)) ': Output (RouteTo (Maybe ByteString)) ': '[]) r
      runUnserialized'''''''' = serializeOutput . deserializeInput
      runUnserialized''''''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF Self ': Output Self ': '[]) r
      runUnserialized''''''''' = serializeOutput . deserializeInput
      runUnserialized'''''''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom (Maybe Handshake)) ': Output (RouteTo (Maybe Handshake)) ': '[]) r
      runUnserialized'''''''''' = serializeOutput . deserializeInput
      runUnserialized''''''''''' :: (Member Trace r, Member Fail r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Trace r) => InterpretersFor (InputWithEOF (RoutedFrom Connection) ': Output (RouteTo Connection) ': '[]) r
      runUnserialized''''''''''' = serializeOutput . deserializeInput
      runUnserializedAny :: (Member Trace r, Member Decoder r, Member ByteInputWithEOF r, Member ByteOutput r, Member Fail r) => InterpretersFor (InputAny ShowAndSerialize ': OutputAny ShowAndSerialize ': '[]) r
      runUnserializedAny = serializeAnyOutput . deserializeAnyInput
      runTransport f s = closeToSocket timeout s . outputToSocket s . inputToSocket bufferSize s . f . raise2Under @ByteInputWithEOF . raise2Under @ByteOutput
      runSocket s =
        acceptToIO s
          . runScopedBundle @(Any ShowAndSerialize) (runTransport runUnserializedAny)
          . runScopedBundle @(TransportEffects Handshake Response) (runTransport runUnserialized)
          . runScopedBundle @(TransportEffects (RouteTo ByteString) (RoutedFrom ByteString)) (runTransport runUnserialized')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe (RoutedFrom Connection))) (RouteTo (Maybe (RouteTo Connection)))) (runTransport runUnserialized'')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))))) (RouteTo (Maybe (RouteTo (Maybe (RouteTo (Maybe ByteString))))))) (runTransport runUnserialized''')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString)))) (RouteTo (Maybe (RouteTo (Maybe ByteString))))) (runTransport runUnserialized'''')
          . runScopedBundle @(TransportEffects (RouteTo (Maybe (RouteTo (Maybe ByteString)))) (RoutedFrom (Maybe (RoutedFrom (Maybe ByteString))))) (runTransport runUnserialized''''')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe (RoutedFrom (Maybe Handshake)))) (RouteTo (Maybe (RouteTo (Maybe Handshake))))) (runTransport runUnserialized'''''')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe (RouteTo ByteString))) (RouteTo (Maybe (RoutedFrom ByteString)))) (runTransport runUnserialized''''''')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString))) (runTransport runUnserialized'''''''')
          . runScopedBundle @(TransportEffects Self Self) (runTransport runUnserialized''''''''')
          . runScopedBundle @(TransportEffects (RoutedFrom (Maybe Handshake)) (RouteTo (Maybe Handshake))) (runTransport runUnserialized'''''''''')
          . runScopedBundle @(TransportEffects (RoutedFrom Connection) (RouteTo Connection)) (runTransport runUnserialized''''''''''')
      runAtomicState = void . atomicStateToIO initialState
      runProcess = scopedProcToIOFinal bufferSize
      run s =
        runFinal @IO
          . asyncToIOFinal
          . resourceToIOFinal
          . runDecoder
          . embedToFinal @IO
          . failToEmbed @IO
          . traceToStdoutBuffered
          . runProcess
          . runSocket s
          . runAtomicState
      forkIf True m = forkProcess m >> exitSuccess
      forkIf False m = m
   in withPnetSocket \s -> do
        (Options maybeSocketPath daemon self cmd) <- parse
        addr <- pnetSocketAddr maybeSocketPath
        bind s addr
        listen s 5
        forkIf daemon . run s $ pnetd self cmd
