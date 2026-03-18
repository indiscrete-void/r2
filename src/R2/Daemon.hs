module R2.Daemon (DaemonEffects, processClients, logToTrace, r2dTasks, r2d, r2dToIO) where

import Control.Concurrent.STM.TBMQueue (TBMQueue)
import Control.Exception (IOException, finally)
import Control.Monad
import Data.ByteString (ByteString)
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Conc (Race)
import Polysemy.Conc.Effect.Events
import Polysemy.Conc.Interpreter.Events
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Internal.Kind (Append)
import Polysemy.Resource (Resource, resourceToIOFinal)
import Polysemy.Scoped
import Polysemy.ScopedBundle
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Daemon.Handler
import R2.Daemon.Sockets
import R2.Daemon.Sockets.Accept
import R2.Encoding.LengthPrefix
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log
import R2.Peer.Storage
import R2.Socket
import System.IO

acceptSockets ::
  ( Member (Accept sock) r,
    Member (Sockets ByteString ByteString sock) r,
    Member (Bus chan ByteString) r,
    Member Async r,
    Member (Peer chan) r
  ) =>
  Sem r ()
acceptSockets = foreverAcceptAsync \s -> do
  chan <- makeBidirectionalChan
  async_ $ socket s $ lenDecodeInput . lenPrefixOutput $ chanToIO chan
  _ <- superviseNode emptyAddrSet Socket chan
  pure ()

processClients ::
  ( Member (Bus chan ByteString) r,
    Member Async r,
    Member (Peer chan) r,
    Member (Storage chan) r,
    Member (Output Log) r,
    Member (EventConsumer (Event chan)) r
  ) =>
  Sem r ()
processClients =
  nodesReaderToStorage $
    subscribe $
      forever $
        consume >>= \case
          ConnFullyInitialized conn@Connection {connHighLevelChan = HighLevel connHighLevelChan} ->
            async_ do
              result <- runFail $ ioToChan connHighLevelChan $ handle (handleMsg conn)
              case result of
                Left err -> output (LogError (connAddrSet conn) err)
                Right _ -> pure ()
          _ -> pure ()

type DaemonEffects chan sock =
  '[ Output Log,
     Storage chan,
     Sockets ByteString ByteString sock,
     Accept sock,
     Fail,
     Bus chan ByteString,
     Events (Event chan),
     EventConsumer (Event chan),
     Async,
     Resource
   ]

r2dTasks ::
  ( Members (DaemonEffects chan sock) r,
    Member (Peer chan) r
  ) =>
  [Sem r ()]
r2dTasks = [processClients, acceptSockets]

r2d :: (Members (DaemonEffects chan sock) r) => AddrSet NameAddr -> Sem r ()
r2d self = runOverlay self $ sequenceConcurrently_ r2dTasks

type DaemonInterpreterEffects =
  Append
    (DaemonEffects (TBMQueue ByteString) IO.Socket)
    '[ Embed IO,
       Race,
       Final IO
     ]

r2dToIO :: Verbosity -> FilePath -> Sem DaemonInterpreterEffects () -> IO ()
r2dToIO verbosity socketPath m = do
  s <- r2Socket
  IO.bind s (IO.SockAddrUnix socketPath)
  IO.listen s 5
  run verbosity s m `finally` IO.close s
  where
    runScopedSocket :: (Member (Embed IO) r, Member Trace r) => Int -> InterpreterFor (Scoped IO.Socket (Bundle ByteTransport)) r
    runScopedSocket bufferSize =
      runScopedBundle @ByteTransport (runSocketIO bufferSize)

    runServerSocket :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpretersFor '[Scoped IO.Socket (Bundle ByteTransport), Accept IO.Socket] r
    runServerSocket bufferSize s = acceptToIO s . runScopedSocket bufferSize

    run verbosity s =
      runFinal @IO
        . interpretRace
        . (embedToFinal @IO)
        . traceIOExceptions @IOException stdout
        . resourceToIOFinal
        . asyncToIOFinal
        . interpretEventsChan
        . interpretBusTBM @ByteString queueSize
        . failToEmbed @IO
        . (ignoreTrace . runServerSocket bufferSize s . raise2Under @Trace)
        . storageToIO
        . (traceToStdoutBuffered . logToTrace verbosity . raiseUnder @Trace)
