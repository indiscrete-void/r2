module R2.Manager
  ( DaemonDescription (..),
    DaemonConnectionCmdResolver (..),
    DaemonConnection (..),
    mkConnectionCmdResolver,
    runManagedDaemon,
    runManagedDaemonIO,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad
import Data.List (isInfixOf)
import Data.List.Extra (replace)
import Data.Set qualified as Set
import Data.Time.Units
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace (traceToStderrBuffered)
import Polysemy.Fail
import Polysemy.Internal.Kind (Append)
import Polysemy.Process (execIO, scopedProcToIOFinal, wait)
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Trace
import R2
import R2.Client
import R2.Daemon
import R2.Options
import R2.Peer (bufferSize)
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

data DaemonDescription = DaemonDescription
  { daemonAddress :: AddrSet LabelAddr,
    daemonSocketPath :: FilePath,
    daemonLinks :: [DaemonConnection],
    daemonServices :: [DaemonConnection],
    daemonVerbosity :: Verbosity
  }

connRestartDelay :: Integer
connRestartDelay = toMicroseconds (2718 :: Millisecond)

stdoutShell :: String -> CreateProcess
stdoutShell cmd = (shell cmd) {std_err = UseHandle stdout}

callCommandNoCtrlC :: (Member (Scoped CreateProcess Sem.Process) r, Member Fail r) => String -> Sem r ()
callCommandNoCtrlC cmd = execIO (stdoutShell cmd) do
  exitCode <- wait
  case exitCode of
    ExitSuccess -> return ()
    ExitFailure r -> fail $ printf "%s: (exit %d)" cmd r

runDaemonConn :: (Member (Scoped CreateProcess Sem.Process) r, Member Fail r) => ConnAction -> DaemonConnection -> Sem r ()
runDaemonConn action DaemonConnection {daemonConnProcess = DaemonConnectionCmdResolver resolve} =
  let resolvedCmd = resolve action
   in callCommandNoCtrlC resolvedCmd

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

runManagedDaemon :: forall chan s r. (Members (ManagerEffects chan s) r) => DaemonDescription -> Sem r ()
runManagedDaemon DaemonDescription {..} = do
  daemon <- async $ r2d $ mapAddrSet NameLabelAddr daemonAddress
  forM_ daemonLinks (async . runManagedDaemonConn)
  forM_ daemonServices (async . runDaemonService)
  await_ daemon

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
