module R2.Daemon (acceptSockets, logToTrace, r2d, r2Socketd, r2dIO) where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar)
import Control.Exception (IOException, finally)
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
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
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log
import R2.Peer.MakeNode
import R2.Peer.Storage
import R2.Socket

acceptSockets ::
  ( Member (Accept sock) r,
    Member (Sockets ByteString ByteString sock) r,
    Member (Bus chan ByteString) r,
    Member Async r,
    Member (MakeNode chan) r
  ) =>
  Sem r ()
acceptSockets =
  foreverAcceptAsync \s -> do
    chan <- makeAcceptedNode Nothing Socket
    socket s $ chanToIO chan

r2d ::
  ( Member (Bus chan ByteString) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  InterpretersFor (Peer chan) r
r2d self = runPeer self (handleR2MsgDefaultAndRestWith $ \conn msg -> nodesReaderToStorage $ whenJust msg $ handleMsg conn)

r2Socketd ::
  ( Member (Accept sock) r,
    Member (Storage chan) r,
    Member (Sockets ByteString ByteString sock) r,
    Member (Bus chan ByteString) r,
    Member Resource r,
    Member Async r,
    Member (Output Log) r
  ) =>
  Address ->
  Sem r ()
r2Socketd self = r2d self acceptSockets

r2dIO :: Verbosity -> Bool -> Address -> FilePath -> IO (Maybe (MVar ()))
r2dIO verbosity fork self socketPath = do
  s <- r2Socket
  IO.bind s (IO.SockAddrUnix socketPath)
  IO.listen s 5
  forkIf fork $
    run verbosity s (r2Socketd self) `finally` IO.close s
  where
    forkIf :: Bool -> IO () -> IO (Maybe (MVar ()))
    forkIf True m = do
      exit <- newEmptyMVar
      _ <- forkIO (m >> putMVar exit ())
      pure $ Just exit
    forkIf False m = Nothing <$ m

    runScopedSocket :: (Member (Embed IO) r, Member Trace r) => Int -> InterpreterFor (Scoped IO.Socket (Bundle ByteTransport)) r
    runScopedSocket bufferSize =
      runScopedBundle @ByteTransport (runSocketIO bufferSize)

    runServerSocket :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpretersFor '[Scoped IO.Socket (Bundle ByteTransport), Accept IO.Socket] r
    runServerSocket bufferSize s = acceptToIO s . runScopedSocket bufferSize

    run verbosity s =
      runFinal @IO
        . interpretRace
        . asyncToIOFinal
        . resourceToIOFinal
        . embedToFinal @IO
        . traceIOExceptions @IOException
        . interpretBusTBM queueSize
        . failToEmbed @IO
        -- ignore interpreter logs
        . ignoreTrace
        -- process and socket io
        . scopedProcToIOFinal bufferSize
        . runServerSocket bufferSize s
        -- AtomicRef storage
        . storageToIO
        -- log application events
        . traceToStdoutBuffered
        . logToTrace verbosity
