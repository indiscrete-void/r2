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
import Data.List.Extra
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
import R2.Options
import R2.Peer
import R2.Peer.Conn
import R2.Peer.Log qualified as Peer
import R2.Peer.MakeNode
import R2.Peer.Proto
import R2.Peer.Storage
import R2.Random
import System.Exit (ExitCode (..))
import System.Process.Extra
import Text.Printf (printf)

newtype NetworkNode = NetworkNode
  { nodeId :: Address
  }
  deriving stock (Show, Eq, Ord)

type NetworkRoute = [NetworkNode]

type NetworkLink = (NetworkNode, NetworkNode)

type ServeList = [(NetworkNode, Service)]

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
    Member (Scoped Address (Output Peer.Log)) r,
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
      scoped @_ @(Output Peer.Log) myId $
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
    Member (Scoped CreateProcess Sem.Process) r,
    Member (Output String) r,
    Member Fail r,
    Member Resource r,
    Member (Scoped Address (AtomicState (NodeState msgChan))) r,
    Member (Scoped Address (Output Peer.Log)) r,
    Member (Scoped Address (Output Client.Log)) r,
    Member Random r
  ) =>
  Map NetworkNode Service ->
  NetworkRoute ->
  Action ->
  InterpretersFor (Transport ByteString ByteString) r
mkActor serveMap (firstNode@NetworkNode {nodeId = firstNodeId} : path) action m = do
  (stdioLinkA, stdioLinkB) <- makeLink @stdioChan @ByteString
  (msgLinkA, msgLinkB) <- makeLink @msgChan @Message

  randAddress <- childAddr firstNodeId

  let (ServiceCommand cmd) = serveMap ! firstNode
  scoped @_ @(AtomicState _) firstNodeId $
    scoped @_ @(Output Peer.Log) firstNodeId $
      storageToAtomicState $
        r2d firstNodeId cmd do
          makeNode $ AcceptedNode (NewConnection (Just randAddress) Socket msgLinkA)

  let command = Command (map nodeId path) action
  client <-
    async $
      scoped @_ @(Output Client.Log) randAddress $
        scoped @_ @(Output Peer.Log) randAddress $
          scoped @_ @(AtomicState _) randAddress $
            storageToAtomicState $
              ioToChan @_ @ByteString stdioLinkA $
                ioToChan @_ @Message msgLinkB $
                  r2c (Just randAddress) command

  result <- ioToChan stdioLinkB m
  await_ client
  pure result
mkActor _ path _ _ = fail $ "invalid path " <> show path

type NetworkEffects msgChan stdioChan =
  '[ Random,
     Scoped CreateProcess Sem.Process,
     Bus msgChan Message,
     Bus stdioChan ByteString,
     Scoped Address (Output Peer.Log),
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

dslToIO :: forall a. Verbosity -> ServeList -> Sem (NetworkEffects (TBMQueue Message) (TBMQueue ByteString)) a -> IO a
dslToIO verbosity serveList =
  let serveMap = Map.fromList serveList
   in runFinal
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
        . runScopedNew @_ @(Output Peer.Log)
          ( \addr ->
              let ServiceCommand service = serveMap ! NetworkNode addr
               in traceTagged (show addr) . Peer.logToTrace verbosity service . raiseUnder @Trace
          )
        . interpretBusTBM @_ @ByteString queueSize
        . interpretBusTBM @_ @Message queueSize
        . scopedProcToIOFinal bufferSize
        . randomToIO

data DaemonConnectionCmd
  = PositiveConnectionCmd String
  | ResolvedNegativeConnectionCmd String
  deriving stock (Show)

negativeCmdPattern :: String
negativeCmdPattern = "-%"

resolveConnectionCmd :: Verbosity -> FilePath -> Maybe Address -> String -> DaemonConnectionCmd
resolveConnectionCmd verbosity socketPath daemonConnAddress daemonConnProcess =
  if negativeCmdPattern `isInfixOf` daemonConnProcess
    then
      let connectCmd :: String = printf "'r2 %s --socket %s connect %s -'" r2Opts socketPath connectOpts
            where
              r2Opts :: String = if verbosity > 0 then printf "-%s" (replicate verbosity 'v') else ""
              connectOpts :: String = case daemonConnAddress of Just (Addr addr) -> printf "-n %s" addr; Nothing -> ""
       in ResolvedNegativeConnectionCmd $ replace "-%" connectCmd daemonConnProcess
    else PositiveConnectionCmd daemonConnProcess

data DaemonConnection = DaemonConnection
  { daemonConnProcess :: DaemonConnectionCmd,
    daemonConnAddress :: Maybe Address
  }

data DaemonDescription = DaemonDescription
  { daemonAddress :: Address,
    daemonSocketPath :: FilePath,
    daemonTunnelProcess :: String,
    daemonLinks :: [DaemonConnection],
    daemonVerbosity :: Verbosity
  }

connRestartDelay :: Integer
connRestartDelay = toMicroseconds (2718 :: Millisecond)

callCommandNoCtrlC :: String -> IO ()
callCommandNoCtrlC cmd = IO.bracketOnError (createProcess $ shell cmd) cleanupProcess \(_, _, _, ph) -> do
  exitCode <- waitForProcess ph
  case exitCode of
    ExitSuccess -> return ()
    ExitFailure r -> fail $ printf "%s: (exit %d)" cmd r

runDaemonConn :: Verbosity -> FilePath -> DaemonConnection -> IO ()
runDaemonConn daemonVerbosity daemonSocketPath (DaemonConnection {daemonConnAddress, daemonConnProcess = PositiveConnectionCmd cmd}) =
  r2cIO daemonVerbosity Nothing daemonSocketPath $ Command [] (Connect (Process cmd) daemonConnAddress)
runDaemonConn _ _ (DaemonConnection {daemonConnProcess = ResolvedNegativeConnectionCmd cmd}) = callCommandNoCtrlC cmd

runManagedDaemonConn :: Verbosity -> FilePath -> DaemonConnection -> IO ()
runManagedDaemonConn daemonVerbosity daemonSocketPath conn@(DaemonConnection linkCmd mConnAddr) = do
  let displayConnAddr :: String = maybe "" (printf " (%s)" . show) mConnAddr
  printf "starting conn %s%s\n" (show linkCmd) displayConnAddr
  result <- IO.try @SomeException $ runDaemonConn daemonVerbosity daemonSocketPath conn
  let displayDelay = show $ fromInteger @Second connRestartDelay
  let displayCause :: String = case result of
        Right () -> "exited"
        Left err -> printf "exited unexpectedly: %s" (show err)
  printf "conn %s%s %s. restarting in %s\n" (show linkCmd) displayConnAddr displayCause displayDelay
  threadDelay $ fromInteger connRestartDelay
  runManagedDaemonConn daemonVerbosity daemonSocketPath (DaemonConnection linkCmd mConnAddr)

runManagedDaemon :: DaemonDescription -> IO (MVar ())
runManagedDaemon DaemonDescription {..} = do
  Just joinDaemon <- r2dIO daemonVerbosity True daemonAddress daemonSocketPath daemonTunnelProcess
  forM_ daemonLinks (forkIO . runManagedDaemonConn daemonVerbosity daemonSocketPath)
  pure joinDaemon
