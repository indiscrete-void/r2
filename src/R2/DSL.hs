module R2.DSL where

import Control.Concurrent (MVar, forkIO, takeMVar, threadDelay)
import Control.Concurrent.Async (Async)
import Control.Concurrent.STM.TBMQueue
import Control.Exception (SomeException)
import Control.Exception qualified as IO
import Control.Monad
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
import Polysemy.Process (scopedProcToIOFinal)
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
import R2.Peer.Proto
import R2.Peer.Storage
import R2.Random
import System.Exit (ExitCode (..))
import System.IO
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
    conn :: NetworkRoute -> Action -> InterpretersFor ByteTransport r,
    conn_ :: NetworkRoute -> Action -> Sem r ()
  }

node :: String -> NetworkNode
node = NetworkNode . Addr

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
    Member (Scoped Address (Output Peer.Log)) r,
    Member Resource r,
    Member (Storages chan) r,
    Member (Scoped Address (Bundle (EventEffects (Event chan)))) r,
    Member Fail r
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
        scoped @_ @(Storage _) myId $
          scoped @_ @(Storage _) myId $
            (scoped @_ @(Bundle (EventEffects _)) myId . bundleEvents) $
              runOverlay myId do
                let myLinks = map (\(a, b) -> if a == me then b else a) . filter (\(a, b) -> a == me || b == me) $ link
                forM_ myLinks \them -> do
                  let chan = links ! (me, them)
                  superviseNode (Just $ nodeId them) Socket chan
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
    Member (Scoped Address (Output Peer.Log)) r,
    Member (Scoped Address (Output Client.Log)) r,
    Member (Scoped Address (Bundle (EventEffects (Event chan)))) r,
    Member Random r
  ) =>
  Map NetworkNode Service ->
  NetworkRoute ->
  Action ->
  InterpretersFor ByteTransport r
mkActor serveMap (firstNode@NetworkNode {nodeId = firstNodeId} : path) action m = do
  (stdioLinkA, stdioLinkB) <- makeLink
  (msgLinkA, msgLinkB) <- makeLink

  randAddress <- childAddr firstNodeId

  let (ServiceCommand cmd) = serveMap ! firstNode
  scoped @_ @(Storage _) firstNodeId $
    scoped @_ @(Output Peer.Log) firstNodeId $
      (scoped @_ @(Bundle (EventEffects _)) firstNodeId . bundleEvents) $
        runOverlay firstNodeId do
          _ <- superviseNode (Just randAddress) Socket msgLinkA
          processClients

  let command = Command (map nodeId path) action
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
     Scoped Address (Bundle (EventEffects (Event (TBMQueue ByteString)))),
     Bus (TBMQueue ByteString) ByteString,
     Scoped Address (Output Peer.Log),
     Scoped Address (Output Client.Log),
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

data ConnAction = ConnServe | ConnAnnounce
  deriving stock (Show)

connActionToCLI :: ConnAction -> String
connActionToCLI ConnServe = "serve"
connActionToCLI ConnAnnounce = "connect"

data DaemonConnectionCmd
  = PositiveConnectionCmd String
  | NegativeConnectionCmdResolver (ConnAction -> String)

negativeCmdPattern :: String
negativeCmdPattern = "-%"

actionCmdPattern :: String
actionCmdPattern = "%ACTION"

connActionToAction :: ConnAction -> String -> Maybe Address -> Action
connActionToAction ConnServe positiveCmd mAddr = Serve mAddr (Process positiveCmd)
connActionToAction ConnAnnounce positiveCmd mAddr = Connect (Process positiveCmd) mAddr

resolveNegativeConnectionCmdAction :: String -> ConnAction -> String
resolveNegativeConnectionCmdAction cmd action = replace actionCmdPattern (connActionToCLI action) cmd

resolveConnectionCmd :: Verbosity -> FilePath -> Maybe Address -> String -> DaemonConnectionCmd
resolveConnectionCmd verbosity socketPath daemonConnAddress daemonConnProcess =
  if negativeCmdPattern `isInfixOf` daemonConnProcess
    then
      let actionCmd :: String = printf "'r2 %s --socket %s %s %s -'" r2Opts socketPath actionCmdPattern actionOpts
            where
              r2Opts :: String = if verbosity > 0 then printf "-%s" (replicate verbosity 'v') else ""
              actionOpts :: String = case daemonConnAddress of Just (Addr addr) -> printf "-n %s" addr; Nothing -> ""
          partialCmd = replace negativeCmdPattern actionCmd daemonConnProcess
       in NegativeConnectionCmdResolver (resolveNegativeConnectionCmdAction partialCmd)
    else PositiveConnectionCmd daemonConnProcess

data DaemonConnection = DaemonConnection
  { daemonConnProcess :: DaemonConnectionCmd,
    daemonConnAddress :: Maybe Address
  }

data DaemonDescription = DaemonDescription
  { daemonAddress :: Address,
    daemonSocketPath :: FilePath,
    daemonLinks :: [DaemonConnection],
    daemonServices :: [DaemonConnection],
    daemonVerbosity :: Verbosity
  }

connRestartDelay :: Integer
connRestartDelay = toMicroseconds (2718 :: Millisecond)

stdoutShell :: String -> CreateProcess
stdoutShell cmd = (shell cmd) {std_err = UseHandle stdout}

callCommandNoCtrlC :: String -> IO ()
callCommandNoCtrlC cmd = IO.bracketOnError (createProcess $ stdoutShell cmd) cleanupProcess \(_, _, _, ph) -> do
  exitCode <- waitForProcess ph
  case exitCode of
    ExitSuccess -> return ()
    ExitFailure r -> fail $ printf "%s: (exit %d)" cmd r

runDaemonConn :: ConnAction -> Verbosity -> FilePath -> DaemonConnection -> IO ()
runDaemonConn action daemonVerbosity daemonSocketPath (DaemonConnection {daemonConnAddress, daemonConnProcess = PositiveConnectionCmd cmd}) =
  let resolvedAction = connActionToAction action cmd daemonConnAddress
   in r2cIO stdout daemonVerbosity Nothing daemonSocketPath $ Command [] resolvedAction
runDaemonConn action _ _ (DaemonConnection {daemonConnProcess = NegativeConnectionCmdResolver resolve}) =
  let resolvedCmd = resolve action
   in callCommandNoCtrlC resolvedCmd

showLinkCmd :: DaemonConnectionCmd -> ConnAction -> String
showLinkCmd (PositiveConnectionCmd cmd) _ = cmd
showLinkCmd (NegativeConnectionCmdResolver resolve) action = resolve action

runManagedDaemonConn :: Verbosity -> FilePath -> DaemonConnection -> IO ()
runManagedDaemonConn daemonVerbosity daemonSocketPath conn@(DaemonConnection linkCmd mConnAddr) = do
  let displayConnAddr :: String = maybe "" (printf " (%s)" . show) mConnAddr
  printf "starting conn %s%s\n" (showLinkCmd linkCmd ConnAnnounce) displayConnAddr
  result <- IO.try @SomeException $ runDaemonConn ConnAnnounce daemonVerbosity daemonSocketPath conn
  let displayDelay = show $ fromMicroseconds @Second connRestartDelay
  let displayCause :: String = case result of
        Right () -> "exited"
        Left err -> printf "exited unexpectedly: %s" (show err)
  printf "conn %s%s %s. restarting in %s\n" (showLinkCmd linkCmd ConnAnnounce) displayConnAddr displayCause displayDelay
  threadDelay $ fromInteger connRestartDelay
  runManagedDaemonConn daemonVerbosity daemonSocketPath (DaemonConnection linkCmd mConnAddr)

runDaemonService :: Verbosity -> FilePath -> DaemonConnection -> IO ()
runDaemonService daemonVerbosity daemonSocketPath conn@(DaemonConnection linkCmd mConnAddr) = do
  let displayServiceAddr :: String = maybe "" (printf " (%s)" . show) mConnAddr
  printf "starting service %s%s\n" (showLinkCmd linkCmd ConnServe) displayServiceAddr
  runDaemonConn ConnServe daemonVerbosity daemonSocketPath conn

runManagedDaemon :: DaemonDescription -> IO ()
runManagedDaemon DaemonDescription {..} = do
  Just joinDaemon <- r2dIO daemonVerbosity True daemonAddress daemonSocketPath
  forM_ daemonLinks (forkIO . runManagedDaemonConn daemonVerbosity daemonSocketPath)
  forM_ daemonServices (forkIO . runDaemonService daemonVerbosity daemonSocketPath)
  takeMVar joinDaemon
