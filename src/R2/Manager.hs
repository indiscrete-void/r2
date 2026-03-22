module R2.Manager
  ( DaemonDescription (..),
    DaemonConnectionCmdResolver (..),
    DaemonConnection (..),
    DaemonTaskEnv,
    DaemonTaskCmdResolver (..),
    DaemonTask (..),
    mkConnectionCmdResolver,
    runManagedDaemon,
    runManagedDaemonIO,
    mkTaskCmdResolver,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad
import Control.Monad.Extra (whenJust)
import Data.List (isInfixOf)
import Data.List.Extra (replace)
import Data.Set qualified as Set
import Data.Time.Units
import Polysemy
import Polysemy.Async
import Polysemy.Conc.Effect.Events
import Polysemy.Conc.Interpreter.Events
import Polysemy.Extra.Trace (traceToStderrBuffered)
import Polysemy.Fail
import Polysemy.Internal.Kind (Append)
import Polysemy.Process (execIO, scopedProcToIOFinal, wait)
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Trace
import R2
import R2.Daemon
import R2.Options
import R2.Peer (bufferSize, runOverlay)
import R2.Peer.Conn
import R2.Peer.FilePaths
import R2.Peer.Proto
import R2.Random
import System.Exit (ExitCode (..))
import System.IO
import System.Process.Extra (CreateProcess (..), StdStream (..), shell)
import Text.Printf (printf)

data Delay m a where
  Delay :: Int -> Delay m ()

makeSem ''Delay

delayToIO :: (Member (Embed IO) r) => Sem (Delay ': r) a -> Sem r a
delayToIO = interpret \(Delay time) -> embed (threadDelay time)

type ManagerEffects chan sock =
  Append
    (DaemonEffects chan sock)
    '[ Scoped CreateProcess Sem.Process,
       Delay,
       Trace,
       Random
     ]

data ConnAction = ConnServe | ConnAnnounce
  deriving stock (Show)

connActionToCLI :: ConnAction -> String
connActionToCLI ConnServe = "serve"
connActionToCLI ConnAnnounce = "connect"

newtype DaemonConnectionCmdResolver = DaemonConnectionCmdResolver (ConnAction -> String)

negativeCmdPattern :: String
negativeCmdPattern = "-%"

actionCmdPattern :: String
actionCmdPattern = "%ACTION"

resolveConnectionCmdAction :: String -> ConnAction -> String
resolveConnectionCmdAction cmd action = replace actionCmdPattern (connActionToCLI action) cmd

mkConnectionCmdResolver :: Verbosity -> FilePath -> AddrSet LabelAddr -> String -> DaemonConnectionCmdResolver
mkConnectionCmdResolver verbosity socketPath daemonConnAddress daemonConnProcess =
  let singleQuoteCmd = printf "'%s'"
      actionCmd transport = printf "r2 %s --socket %s %s %s %s" r2Opts socketPath actionCmdPattern actionOpts transportArg
        where
          r2Opts :: String = if verbosity > 0 then printf "-%s" (replicate verbosity 'v') else ""
          actionOpts :: String = unwords $ map (printf "-n %s" . show) (Set.toList $ unAddrSet daemonConnAddress)
          transportArg :: String = case transport of
            Stdio -> "-"
            Process cmd -> singleQuoteCmd cmd
      partialCmd =
        if negativeCmdPattern `isInfixOf` daemonConnProcess
          then replace negativeCmdPattern (singleQuoteCmd $ actionCmd Stdio) daemonConnProcess
          else actionCmd (Process daemonConnProcess)
   in DaemonConnectionCmdResolver (resolveConnectionCmdAction partialCmd)

data DaemonConnection = DaemonConnection
  { daemonConnProcess :: DaemonConnectionCmdResolver,
    daemonConnAddress :: AddrSet LabelAddr
  }

newtype DaemonTaskCmdResolver = DaemonTaskCmdResolver (NameAddr -> String)

type DaemonTaskEnv = [(String, FilePath)]

data DaemonTask = DaemonTask
  { daemonTaskTriggers :: AddrSet NameAddr,
    daemonTaskProcess :: DaemonTaskCmdResolver,
    daemonTaskEnv :: DaemonTaskEnv
  }

findAddrMatch :: AddrSet NameAddr -> AddrSet NetworkAddr -> Maybe NameAddr
findAddrMatch taskTriggers testSet = do
  name <- bestAddrSetName testSet
  if name `elem` taskTriggers
    then Just name
    else Nothing

addrCmdPattern :: String
addrCmdPattern = "%addr"

-- mkTaskCmdResolver cmd creates a
-- DaemonTaskCmdResolver :: name@NameAddr -> String
-- which replaces "%addr" with name in cmd
mkTaskCmdResolver :: String -> DaemonTaskCmdResolver
mkTaskCmdResolver daemonTaskCmd = DaemonTaskCmdResolver \name ->
  replace addrCmdPattern (show name) daemonTaskCmd

data DaemonDescription = DaemonDescription
  { daemonAddress :: AddrSet LabelAddr,
    daemonSocketPath :: FilePath,
    daemonLinks :: [DaemonConnection],
    daemonTasks :: [DaemonTask],
    daemonServices :: [DaemonConnection],
    daemonVerbosity :: Verbosity
  }

connRestartDelay :: Integer
connRestartDelay = toMicroseconds (2718 :: Millisecond)

stdoutShell :: String -> CreateProcess
stdoutShell cmd = (shell cmd) {std_err = UseHandle stdout}

callCommandNoCtrlC :: (Member (Scoped CreateProcess Sem.Process) r, Member Fail r) => CreateProcess -> Sem r ()
callCommandNoCtrlC processSpec = execIO processSpec do
  exitCode <- wait
  case exitCode of
    ExitSuccess -> return ()
    ExitFailure r -> fail $ printf "%s: (exit %d)" (show $ cmdspec processSpec) r

runDaemonConn :: (Member (Scoped CreateProcess Sem.Process) r, Member Fail r) => ConnAction -> DaemonConnection -> Sem r ()
runDaemonConn action DaemonConnection {daemonConnProcess = DaemonConnectionCmdResolver resolve} =
  let resolvedCmd = resolve action
   in callCommandNoCtrlC (stdoutShell resolvedCmd)

displayConnAddr :: (Show addr) => AddrSet addr -> String
displayConnAddr connAddrSet = if null connAddrSet then "" else printf " %s" (show connAddrSet)

runManagedDaemonConn ::
  ( Member (Scoped CreateProcess Sem.Process) r,
    Member Trace r,
    Member Delay r
  ) =>
  DaemonConnection ->
  Sem r ()
runManagedDaemonConn conn@(DaemonConnection (DaemonConnectionCmdResolver resolveLinkCmd) connAddrSet) = do
  trace $ printf "starting conn %s%s" (resolveLinkCmd ConnAnnounce) (displayConnAddr connAddrSet)
  result <- runFail $ runDaemonConn ConnAnnounce conn
  let displayDelay = show $ fromMicroseconds @Second connRestartDelay
  let displayCause :: String = case result of
        Right () -> "exited"
        Left err -> printf "exited unexpectedly: %s" (show err)
  trace $ printf "conn %s%s %s. restarting in %s" (resolveLinkCmd ConnAnnounce) (displayConnAddr connAddrSet) displayCause displayDelay
  delay $ fromInteger connRestartDelay
  runManagedDaemonConn conn

runDaemonService :: (Members (ManagerEffects chan s) r) => DaemonConnection -> Sem r ()
runDaemonService conn@(DaemonConnection (DaemonConnectionCmdResolver resolveLinkCmd) connAddrSet) = do
  trace $ printf "starting service %s%s" (resolveLinkCmd ConnServe) (displayConnAddr connAddrSet)
  runDaemonConn ConnServe conn

runDaemonTask :: (Member (Scoped CreateProcess Sem.Process) r, Member Fail r) => DaemonTaskEnv -> FilePath -> String -> Sem r ()
runDaemonTask taskEnv daemonSocketPath cmd =
  let socketEnv = [(r2SocketEnv, daemonSocketPath)]
      spec = (stdoutShell cmd) {env = Just $ socketEnv <> taskEnv}
   in callCommandNoCtrlC spec

whenConnects :: (Member (EventConsumer (Event chan)) r) => AddrSet NameAddr -> (NameAddr -> Sem r ()) -> Sem r a
whenConnects triggers m =
  subscribe $
    forever $
      consume >>= \case
        ConnFullyInitialized (connAddrSet -> addrSet) -> do
          whenJust (findAddrMatch triggers addrSet) (raise . m)
        _ -> pure ()

runManagedDaemonTask :: (Members (ManagerEffects chan s) r) => FilePath -> DaemonTask -> Sem r ()
runManagedDaemonTask daemonSocketPath DaemonTask {daemonTaskTriggers, daemonTaskProcess = DaemonTaskCmdResolver resolveTask, daemonTaskEnv} =
  whenConnects daemonTaskTriggers go
  where
    go triggerAddr = do
      let resolvedCmd = resolveTask triggerAddr
      trace $ printf "starting task `%s`" resolvedCmd
      result <- runFail $ runDaemonTask daemonTaskEnv daemonSocketPath resolvedCmd
      let displayCause :: String = case result of
            Right () -> "exited"
            Left err -> printf "exited unexpectedly: %s" (show err)
      trace $ printf "task '%s' %s" resolvedCmd displayCause

runManagedDaemon :: forall chan s r. (Members (ManagerEffects chan s) r) => DaemonDescription -> Sem r ()
runManagedDaemon DaemonDescription {..} = do
  let self = mapAddrSet NameLabelAddr daemonAddress
  runOverlay self do
    tasks <-
      forM r2dTasks async
        <> forM daemonServices (async . runDaemonService)
        <> forM daemonTasks (async . runManagedDaemonTask daemonSocketPath)
        <> forM daemonLinks (async . runManagedDaemonConn)
    forM_ tasks await

runManagedDaemonIO :: DaemonDescription -> IO ()
runManagedDaemonIO desc@DaemonDescription {daemonVerbosity, daemonSocketPath} = run $ runManagedDaemon desc
  where
    run =
      void
        . r2dToIO daemonVerbosity daemonSocketPath
        . scopedProcToIOFinal bufferSize
        . delayToIO
        . traceToStderrBuffered
        . randomToIO
