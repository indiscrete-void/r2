import Control.Monad
import Data.ByteString (ByteString)
import Data.List qualified as List
import Network.Socket (bind, listen)
import Pnet
import Pnet.Node
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
import Polysemy.Sockets
import Polysemy.Trace
import Polysemy.Transport
import System.Exit
import System.Posix
import Text.Printf qualified as Text

type State s = [(s, Address)]

initialState :: State s
initialState = []

whenJust :: (Monad m) => (a -> m ()) -> Maybe a -> m ()
whenJust = maybe (pure ())

pnetd :: (Member (Accept s) r, Member (Sockets Handshake Response s) r, Member (Sockets (RoutedFrom (Maybe ByteString)) (RouteTo (Maybe ByteString)) s) r, Member (AtomicState (State s)) r, Member Trace r, Member Async r, Eq s, Member Fail r) => Sem r ()
pnetd = foreverAcceptAsync \s -> socket s (inputOrFail >>= go s >> close)
  where
    go _ ListNodes = do
      nodeList <- map snd <$> atomicGet
      traceTagged "ListNodes" (Text.printf "responding with `%s`" (show nodeList))
      output (NodeList nodeList)
    go s (ConnectNode transport maybeNodeID) = do
      traceTagged "NodeAvailability" (Text.printf "%s connected over `%s`" nodeIDStr (show transport))
      whenJust (atomicModify' . (:) . entry) maybeNodeID
      traceTagged "pnetnd" . show =<< runFail (socket s $ runR2 defaultAddr pnetnd')
      traceTagged "NodeAvailability" (Text.printf "%s disconnected from `%s`" nodeIDStr (show transport))
      whenJust (atomicModify' . List.delete . entry) maybeNodeID
      where
        nodeIDStr = maybe "unknown node" show maybeNodeID
        entry nodeID = (s, nodeID)

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
