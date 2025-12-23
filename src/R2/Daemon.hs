module R2.Daemon (acceptSockets, logToTrace, r2d, r2Socketd, r2dIO) where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar)
import Control.Exception (IOException, finally)
import Control.Monad.Extra
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Async
import Polysemy.Bundle
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Resource (Resource, resourceToIOFinal)
import Polysemy.Scoped
import Polysemy.ScopedBundle
import Polysemy.Serialize
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
import R2.Peer.Proto
import R2.Peer.Storage
import R2.Socket
import System.Process.Extra

acceptSockets ::
  ( Member (Accept sock) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Async r,
    Member (MakeNode chan) r
  ) =>
  Sem r ()
acceptSockets =
  foreverAcceptAsync \s -> do
    chan <- makeAcceptedNode Nothing Socket
    socket @Message @Message s $ chanToIO chan

r2d ::
  ( Member (Bus chan Message) r,
    Member (Output Log) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Process) r,
    Member Async r,
    Member Resource r
  ) =>
  Address ->
  String ->
  InterpreterFor (MakeNode chan) r
r2d self cmd = runPeer self (\conn msg -> whenJust msg $ handleMsg cmd conn)

r2Socketd ::
  ( Member (Accept sock) r,
    Member (Storage chan) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Sockets Message Message sock) r,
    Member (Bus chan Message) r,
    Member Resource r,
    Member Async r,
    Member (Output Log) r
  ) =>
  Address ->
  String ->
  Sem r ()
r2Socketd self cmd = r2d self cmd acceptSockets

r2dIO :: Verbosity -> Bool -> Address -> Maybe FilePath -> String -> IO (Maybe (MVar ()))
r2dIO verbosity fork self mSocketPath cmd = do
  addr <- r2SocketAddr mSocketPath
  s <- r2Socket
  IO.bind s addr
  IO.listen s 5
  forkIf fork $
    run verbosity cmd s (r2Socketd self cmd) `finally` IO.close s
  where
    forkIf :: Bool -> IO () -> IO (Maybe (MVar ()))
    forkIf True m = do
      exit <- newEmptyMVar
      _ <- forkIO (m >> putMVar exit ())
      pure $ Just exit
    forkIf False m = Nothing <$ m

    runScopedSocket :: (Member (Embed IO) r, Member Trace r, Member Fail r) => Int -> InterpreterFor (Scoped IO.Socket (Bundle (Transport Message Message))) r
    runScopedSocket bufferSize =
      runScopedBundle @(Transport Message Message)
        ( \s ->
            runSocketIO bufferSize s
              . runSerialization
              . raise2Under @ByteInputWithEOF
              . raise2Under @ByteOutput
        )

    runServerSocket ::
      (Member (Embed IO) r, Member Fail r, Member Trace r) =>
      Int ->
      IO.Socket ->
      InterpretersFor
        '[ Scoped IO.Socket (Bundle (Transport Message Message)),
           Accept IO.Socket
         ]
        r
    runServerSocket bufferSize s = acceptToIO s . runScopedSocket bufferSize

    run verbosity cmd s =
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
        . logToTrace verbosity cmd
