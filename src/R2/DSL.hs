module R2.DSL where

import Control.Concurrent (MVar, forkIO, threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.STM.TBMQueue
import Control.Exception (SomeException)
import Control.Exception qualified as IO
import Control.Monad
import Control.Monad.Extra
import Data.ByteString (ByteString)
import Data.IORef
import Data.List qualified as List
import Data.Map (Map, (!))
import Data.Map qualified as Map
import Data.Time.Units
import Polysemy
import Polysemy.Async (async, await)
import Polysemy.Async qualified as Sem
import Polysemy.AtomicState
import Polysemy.Conc (interpretMaskFinal)
import Polysemy.Conc.Effect.Lock
import Polysemy.Conc.Effect.Mask
import Polysemy.Conc.Effect.Race
import Polysemy.Conc.Interpreter.Lock
import Polysemy.Conc.Interpreter.Race
import Polysemy.Extra.Async
import Polysemy.Extra.Trace (traceTagged, traceToStderrBuffered)
import Polysemy.Fail
import Polysemy.Process (scopedProcToIOFinal)
import Polysemy.Process qualified as Sem
import Polysemy.Resource
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Client
import R2.Client qualified as Client
import R2.Daemon
import R2.Daemon qualified as Daemon
import R2.Daemon.MakeNode
import R2.Daemon.Node
import R2.Daemon.Storage
import R2.Options
import R2.Peer
import System.Process.Extra
import System.Random
import System.Random.Stateful (Uniform (uniformM), newIOGenM)
import Text.Printf (printf)

newtype NetworkNode = NetworkNode
  { nodeId :: Address
  }
  deriving stock (Show, Eq, Ord)

type NetworkRoute = [NetworkNode]

type NetworkLink = (NetworkNode, NetworkNode)

newtype Service = ServiceCommand String

exec :: String -> Service
exec = ServiceCommand

data NetworkDescription = NetworkDescription
  { serve :: [(NetworkNode, Service)],
    link :: [NetworkLink]
  }

static :: NetworkDescription
static = NetworkDescription {serve = [], link = []}

data Network r = Network
  { join :: Sem r (),
    conn :: NetworkRoute -> Action -> InterpretersFor (Transport ByteString ByteString) r,
    conn_ :: NetworkRoute -> Action -> Sem r ()
  }

node :: String -> NetworkNode
node = NetworkNode . Addr

linkChans :: (Member (Bus chan d) r) => Bidirectional chan -> Bidirectional chan -> Sem r ()
linkChans a@Bidirectional {inboundChan} b@Bidirectional {outboundChan} = do
  d <- busChan outboundChan takeChan
  busChan inboundChan $ putChan d
  whenJust d $ const (linkChans a b)

makeLink :: (Member (Bus chan d) r, Member Sem.Async r) => Sem r (Bidirectional chan, Bidirectional chan)
makeLink = do
  aToB <- makeBidirectionalChan
  bToA <- makeBidirectionalChan
  async_ $ linkChans aToB bToA
  async_ $ linkChans bToA aToB
  pure (aToB, bToA)

mkLinks :: (Member (Bus chan Message) r, Member Sem.Async r) => [NetworkLink] -> Sem r (Map NetworkLink (Bidirectional chan))
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

mkNodes ::
  ( Member (Bus chan Message) r,
    Member Sem.Async r,
    Member (Scoped Address (Output Daemon.Log)) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member Resource r,
    Member (Scoped Address (AtomicState (NodeState chan))) r
  ) =>
  [NetworkLink] ->
  Map (NetworkNode, NetworkNode) (Bidirectional chan) ->
  Map NetworkNode Service ->
  Sem r [Async (Maybe ())]
mkNodes link links serveMap = do
  let linkNodes = List.nub $ concat [[a, b] | ((a, b), _) <- Map.toList links]
  forM linkNodes \me@NetworkNode {nodeId = myId} -> do
    let (ServiceCommand service) = serveMap ! me
    async $
      scoped @_ @(Output Daemon.Log) myId $
        scoped @_ @(AtomicState _) myId $
          storageToAtomicState $ r2d myId service do
            let myLinks = map (\(a, b) -> if a == me then b else a) . filter (\(a, b) -> a == me || b == me) $ link
            forM_ myLinks \them -> do
              let chan = links ! (me, them)
              makeNode $ AcceptedNode (NewConnection (Just $ nodeId them) Socket chan)

mkActor ::
  forall msgChan stdioChan r.
  ( Member Sem.Async r,
    Member (Bus msgChan Message) r,
    Member (Bus stdioChan ByteString) r,
    Member (Embed IO) r,
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Resource r,
    Member (Scoped Address (AtomicState (NodeState msgChan))) r,
    Member (Scoped Address (Output Daemon.Log)) r,
    Member (Scoped Address (Output Client.Log)) r
  ) =>
  Map NetworkNode Service ->
  NetworkRoute ->
  Action ->
  InterpretersFor (Transport ByteString ByteString) r
mkActor serveMap (firstNode@NetworkNode {nodeId = firstNodeId} : path) action m = do
  (stdioLinkA, stdioLinkB) <- makeLink @stdioChan @ByteString
  (msgLinkA, msgLinkB) <- makeLink @msgChan @Message

  gen <- embed $ initStdGen >>= newIOGenM
  randAddress <- embed $ uniformM @Address gen

  let (ServiceCommand cmd) = serveMap ! firstNode
  scoped @_ @(AtomicState _) firstNodeId $
    scoped @_ @(Output Daemon.Log) firstNodeId $
      storageToAtomicState $
        r2d firstNodeId cmd do
          makeNode $ AcceptedNode (NewConnection (Just randAddress) Socket msgLinkA)

  let command = Command (map nodeId path) action
  client <-
    async $
      scoped @_ @(Output Client.Log) randAddress $
        ioToChan @_ @ByteString stdioLinkA $
          ioToChan @_ @Message msgLinkB $
            r2c randAddress command

  result <- ioToChan stdioLinkB m
  await_ client
  pure result
mkActor _ path _ _ = fail $ "invalid path " <> show path

type NetworkEffects msgChan stdioChan =
  '[ Scoped CreateProcess Sem.Process,
     Bus msgChan Message,
     Bus stdioChan ByteString,
     Scoped Address (Output Daemon.Log),
     Scoped Address (Output Client.Log),
     Scoped Address (AtomicState (NodeState msgChan)),
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

mkNet :: (Members (NetworkEffects chan stdioChan) r) => NetworkDescription -> Sem r (Network r)
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

storagesToIO ::
  (Member (Embed IO) r, Member Lock r) =>
  Sem (Scoped Address (AtomicState (NodeState (TBMQueue Message))) ': r) a ->
  Sem r a
storagesToIO =
  fmap snd
    . atomicStateToIO Map.empty
    . runScopedNew @_ @(AtomicState (NodeState (TBMQueue Message)))
      ( \addr m -> do
          stateRef <- lock do
            stateMap <- atomicGet
            case Map.lookup addr stateMap of
              Just state -> pure state
              Nothing -> do
                initialState <- embed $ newIORef []
                atomicPut $ Map.insert addr initialState stateMap
                pure initialState
          runAtomicStateIORef stateRef m
      )
    . raiseUnder

dslToIO :: forall a. Verbosity -> Sem (NetworkEffects (TBMQueue Message) (TBMQueue ByteString)) a -> IO a
dslToIO verbosity =
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
    . runScopedNew @_ @(Output Daemon.Log) (\addr -> traceTagged (show addr) . Daemon.logToTrace verbosity "<unknown cmd>" . raiseUnder @Trace)
    . interpretBusTBM @_ @ByteString queueSize
    . interpretBusTBM @_ @Message queueSize
    . scopedProcToIOFinal bufferSize

data DaemonConnection = DaemonConnection
  { daemonConnProcess :: String,
    daemonConnAddress :: Maybe Address
  }

data DaemonDescription = DaemonDescription
  { daemonAddress :: Address,
    daemonSocketPath :: Maybe FilePath,
    daemonTunnelProcess :: String,
    daemonLinks :: [DaemonConnection],
    daemonVerbosity :: Verbosity
  }

connRestartDelay :: Integer
connRestartDelay = toMicroseconds (2718 :: Millisecond)

runManagedDaemonConn :: Verbosity -> Maybe FilePath -> DaemonConnection -> IO ()
runManagedDaemonConn daemonVerbosity daemonSocketPath (DaemonConnection linkCmd mConnAddr) = do
  result <- IO.try @SomeException $ r2cIO daemonVerbosity Nothing daemonSocketPath $ Command [] (Connect (Process linkCmd) mConnAddr)
  let displayConnAddr :: String = maybe "" (printf " (%s)" . show) mConnAddr
  let displayDelay = show $ fromInteger @Second connRestartDelay
  let displayCause :: String = case result of
        Right () -> "exited"
        Left err -> printf "exited unexpectedly: %s" (show err)
  printf "conn %s%s %s. restarting in %s" linkCmd displayConnAddr displayCause displayDelay
  threadDelay $ fromInteger connRestartDelay
  runManagedDaemonConn daemonVerbosity daemonSocketPath (DaemonConnection linkCmd mConnAddr)

runManagedDaemon :: DaemonDescription -> IO (MVar ())
runManagedDaemon DaemonDescription {..} = do
  Just joinDaemon <- r2dIO daemonVerbosity True daemonAddress daemonSocketPath daemonTunnelProcess
  forM_ daemonLinks (forkIO . runManagedDaemonConn daemonVerbosity daemonSocketPath)
  pure joinDaemon
