module R2.DSL where

import Control.Concurrent (MVar, forkIO, takeMVar, threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.STM.TBMQueue
import Control.Exception (SomeException)
import Control.Exception qualified as IO
import Control.Monad
import Control.Monad.Trans.RWS (local)
import Data.ByteString (ByteString)
import Data.List qualified as List
import Data.List.Extra
import Data.Map (Map, (!))
import Data.Map qualified as Map
import Data.Time.Units
import Polysemy
import Polysemy.Async (async, await)
import Polysemy.Async qualified as Sem
import Polysemy.Bundle
import Polysemy.Conc (EventConsumer, Events, interpretEventsChan, interpretMaskFinal)
import Polysemy.Conc.Effect.Lock
import Polysemy.Conc.Effect.Mask
import Polysemy.Conc.Effect.Race
import Polysemy.Conc.Interpreter.Lock
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Async
import Polysemy.Extra.Trace (traceTagged, traceToStderrBuffered)
import Polysemy.Fail
import Polysemy.Process
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.ScopedBundle
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Client
import R2.Client qualified as Client
import R2.Client.Stream
import R2.Daemon
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log qualified as Peer
import R2.Peer.Storage
import R2.Random
import System.Process.Extra

type NetworkLink = (NameAddr, NameAddr)

type ServeList = [(NameAddr, Service)]

newtype Service = ServiceCommand String

exec :: String -> Service
exec = ServiceCommand

data NetworkDescription = NetworkDescription
  { serve :: ServeList,
    link :: [NetworkLink]
  }

static :: NetworkDescription
static = NetworkDescription {serve = [], link = []}

data Network r = Network
  { join :: Sem r (),
    conn :: NetworkAddr -> Action -> InterpretersFor ByteTransport r,
    conn_ :: NetworkAddr -> Action -> Sem r ()
  }

makeLink :: forall chan d r. (Member (Bus chan d) r, Member Sem.Async r) => Sem r (Bidirectional chan, Bidirectional chan)
makeLink = do
  aToB <- makeBidirectionalChan
  bToA <- makeBidirectionalChan
  async_ $ linkChansBidirectional aToB bToA
  pure (aToB, bToA)

mkLinks :: (Member (Bus chan d) r, Member Sem.Async r) => [NetworkLink] -> Sem r (Map NetworkLink (Bidirectional chan))
mkLinks link =
  mconcat
    <$> forM
      link
      ( \(a, b) -> do
          (endA, endB) <- makeLink
          pure $
            mconcat
              [ Map.singleton (a, b) endA,
                Map.singleton (b, a) endB
              ]
      )

type EventEffects e = '[Events e, EventConsumer e]

bundleEvents :: (Member (Bundle (EventEffects e)) r) => InterpretersFor (EventEffects e) r
bundleEvents =
  sendBundle @(EventConsumer _)
    . sendBundle @(Events _)

mkNodes ::
  ( Member (Bus chan ByteString) r,
    Member Sem.Async r,
    Member (Scoped NameAddr (Output Peer.Log)) r,
    Member Resource r,
    Member (Storages chan) r,
    Member (Scoped NameAddr (Bundle (EventEffects (Event chan)))) r,
    Member Fail r
  ) =>
  [NetworkLink] ->
  Map (NameAddr, NameAddr) (Bidirectional chan) ->
  Map NameAddr Service ->
  Sem r [Async (Maybe ())]
mkNodes link links serveMap = do
  let linkNodes = List.nub $ concat [[a, b] | ((a, b), _) <- Map.toList links]
  forM linkNodes \me -> do
    let (ServiceCommand service) = serveMap ! me
    async $
      scoped @_ @(Output Peer.Log) me $
        scoped @_ @(Storage _) me $
          scoped @_ @(Storage _) me $
            (scoped @_ @(Bundle (EventEffects _)) me . bundleEvents) $
              runOverlay me do
                let myLinks = map (\(a, b) -> if a == me then b else a) . filter (\(a, b) -> a == me || b == me) $ link
                forM_ myLinks \them -> do
                  let chan = links ! (me, them)
                  superviseNode (singleAddrSet $ NetworkNameAddr them) Socket chan
                processClients

mkActor ::
  forall chan r.
  ( Member Sem.Async r,
    Member (Bus chan ByteString) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Resource r,
    Member (Storages chan) r,
    Member (Scoped NameAddr (Output Peer.Log)) r,
    Member (Scoped NameAddr (Output Client.Log)) r,
    Member (Scoped NameAddr (Bundle (EventEffects (Event chan)))) r,
    Member Random r
  ) =>
  Map NameAddr Service ->
  NetworkAddr ->
  Action ->
  InterpretersFor ByteTransport r
mkActor serveMap target action m = do
  (stdioLinkA, stdioLinkB) <- makeLink
  (msgLinkA, msgLinkB) <- makeLink

  randAddress <- childAddr "child"

  let firstNodeId = netAddrHead target
  scoped @_ @(Storage _) firstNodeId $
    scoped @_ @(Output Peer.Log) firstNodeId $
      (scoped @_ @(Bundle (EventEffects _)) firstNodeId . bundleEvents) $
        runOverlay firstNodeId do
          _ <- superviseNode (singleAddrSet $ NetworkNameAddr randAddress) Socket msgLinkA
          processClients

  let command = Command (TargetAddrNetwork target) action
  client <-
    async $
      scoped @_ @(Output Client.Log) randAddress $
        scoped @_ @(Output Peer.Log) randAddress $
          (scoped @_ @(Bundle (EventEffects _)) randAddress . bundleEvents) $
            scoped @_ @(Storage _) randAddress $
              streamToChan @'ProcStream stdioLinkA $
                streamToChan @'ServerStream msgLinkB $
                  r2c (Just randAddress) command

  result <- ioToChan stdioLinkB m
  await_ client
  pure result
mkActor _ path _ _ = fail $ "invalid path " <> show path

type NetworkEffects =
  '[ Random,
     Scoped CreateProcess Sem.Process,
     Scoped NameAddr (Bundle (EventEffects (Event (TBMQueue ByteString)))),
     Bus (TBMQueue ByteString) ByteString,
     Scoped NameAddr (Output Peer.Log),
     Scoped NameAddr (Output Client.Log),
     Storages (TBMQueue ByteString),
     Fail,
     Output String,
     Trace,
     Lock,
     Embed IO,
     Sem.Async,
     Resource,
     Race,
     Mask,
     Final IO
   ]

mkNet :: (Members NetworkEffects r) => NetworkDescription -> Sem r (Network r)
mkNet NetworkDescription {..} = do
  let serveMap = Map.fromList serve
  links <- mkLinks link
  handles <- mkNodes link links serveMap
  let conn = mkActor serveMap
  pure $
    Network
      { conn = conn,
        conn_ = \route action -> conn route action (pure ()),
        join = forM_ handles await
      }

dslToIO :: forall a. Verbosity -> ServeList -> Sem NetworkEffects a -> IO a
dslToIO verbosity serveList =
  runFinal
    . interpretMaskFinal
    . interpretRace
    . resourceToIOFinal
    . Sem.asyncToIOFinal
    . embedToFinal @IO
    . interpretLockReentrant
    . traceToStderrBuffered
    . outputToTrace id
    . failToEmbed @IO
    . storagesToIO
    . runScopedNew @_ @(Output Client.Log) (\addr -> traceTagged (show addr) . Client.logToTrace verbosity . raiseUnder @Trace)
    . runScopedNew @_ @(Output Peer.Log) (\addr -> traceTagged (show addr) . Peer.logToTrace verbosity . raiseUnder @Trace)
    . interpretBusTBM @ByteString queueSize
    . runScopedBundle (const interpretEventsChan)
    . scopedProcToIOFinal bufferSize
    . randomToIO
