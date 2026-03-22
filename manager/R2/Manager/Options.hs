module R2.Manager.Options (Options (..), parse) where

import Control.Category ((<<<))
import Data.Maybe
import Data.Text qualified as Text
import Options.Applicative
import R2
import R2.Manager
import R2.Options
import R2.Peer.FilePaths
import System.Environment
import Toml (TomlCodec)
import Toml qualified
import Toml.Codec ((.=))

data Options = Options Verbosity FilePath

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Manages r2d connections"
        <> header "Route-to network daemon manager"
    )

opts :: Parser Options
opts =
  Options
    <$> verbosity
    <*> strOption (long "config" <> short 'f')

data TOMLDaemonOptions = TOMLDaemonOptions
  { tomlDaemonAddress :: AddrSet LabelAddr,
    tomlDaemonSocketPath :: Maybe FilePath
  }

data TOMLDaemonDescription = TOMLDaemonDescription
  { tomlDaemonSelf :: TOMLDaemonOptions,
    tomlDaemonLinks :: [TOMLDaemonConnection],
    tomlDaemonServices :: [TOMLDaemonConnection],
    tomlDaemonTasks :: [TOMLDaemonTask]
  }

data TOMLDaemonConnection = TOMLDaemonConnection
  { tomlDaemonConnProcess :: String,
    tomlDaemonConnAddress :: AddrSet LabelAddr
  }

data TOMLDaemonTask = TOMLDaemonTask
  { tomlDaemonTaskTriggers :: AddrSet LabelAddr,
    tomlDaemonTaskCmd :: String
  }

_LabelAddr :: Toml.BiMap Toml.TomlBiMapError LabelAddr Toml.AnyValue
_LabelAddr = Toml._String <<< Toml.iso labelAddr LabelAddr

tomlSingleAddrSet :: Toml.Key -> TomlCodec (AddrSet LabelAddr)
tomlSingleAddrSet key = Toml.dimap show (singleAddrSet . LabelAddr) $ Toml.string key

tomlAddrSet :: Toml.Key -> TomlCodec (AddrSet LabelAddr)
tomlAddrSet key = Toml.dimap unAddrSet AddrSet (Toml.arraySetOf _LabelAddr key) <|> tomlSingleAddrSet key

tomlOptionalAddrSet :: Toml.Key -> TomlCodec (AddrSet LabelAddr)
tomlOptionalAddrSet key = Toml.dimap Just (fromMaybe emptyAddrSet) $ Toml.dioptional (tomlAddrSet key)

selfCodec :: TomlCodec TOMLDaemonOptions
selfCodec =
  TOMLDaemonOptions
    <$> tomlAddrSet "addr" .= tomlDaemonAddress
    <*> Toml.dioptional (Toml.string "socket") .= tomlDaemonSocketPath

connCodec :: TomlCodec TOMLDaemonConnection
connCodec =
  TOMLDaemonConnection
    <$> Toml.string "cmd" .= tomlDaemonConnProcess
    <*> tomlOptionalAddrSet "addr" .= tomlDaemonConnAddress

taskCodec :: TomlCodec TOMLDaemonTask
taskCodec =
  TOMLDaemonTask
    <$> tomlAddrSet "addr" .= tomlDaemonTaskTriggers
    <*> Toml.string "cmd" .= tomlDaemonTaskCmd

descriptionCodec :: TomlCodec TOMLDaemonDescription
descriptionCodec =
  TOMLDaemonDescription
    <$> Toml.table selfCodec "self" .= tomlDaemonSelf
    <*> Toml.list connCodec "conn" .= tomlDaemonLinks
    <*> Toml.list connCodec "serve" .= tomlDaemonServices
    <*> Toml.list taskCodec "task" .= tomlDaemonTasks

resolveTOMLConnections :: Verbosity -> FilePath -> [TOMLDaemonConnection] -> [DaemonConnection]
resolveTOMLConnections verbosity socketPath =
  map
    ( \(TOMLDaemonConnection {..}) ->
        DaemonConnection
          { daemonConnProcess =
              mkConnectionCmdResolver
                verbosity
                socketPath
                tomlDaemonConnAddress
                tomlDaemonConnProcess,
            daemonConnAddress = tomlDaemonConnAddress
          }
    )

resolveTOMLTasks :: DaemonTaskEnv -> [TOMLDaemonTask] -> [DaemonTask]
resolveTOMLTasks env =
  map
    ( \TOMLDaemonTask {..} ->
        DaemonTask
          { daemonTaskTriggers = mapAddrSet NameLabelAddr tomlDaemonTaskTriggers,
            daemonTaskProcess = mkTaskCmdResolver tomlDaemonTaskCmd,
            daemonTaskEnv = env
          }
    )

parse :: IO DaemonDescription
parse = do
  env <- getEnvironment
  Options verbosity configPath <- execParser parserInfo
  tomlRes <- Toml.decodeFileEither descriptionCodec configPath
  case tomlRes of
    Left errs -> fail $ Text.unpack $ Toml.prettyTomlDecodeErrors errs
    Right TOMLDaemonDescription {tomlDaemonSelf = TOMLDaemonOptions {..}, ..} -> do
      socketPath <- resolveSocketPath tomlDaemonSocketPath
      let links = resolveTOMLConnections verbosity socketPath tomlDaemonLinks
      let services = resolveTOMLConnections verbosity socketPath tomlDaemonServices
      let tasks = resolveTOMLTasks env tomlDaemonTasks
      pure $
        DaemonDescription
          { daemonAddress = tomlDaemonAddress,
            daemonSocketPath = socketPath,
            daemonLinks = links,
            daemonServices = services,
            daemonTasks = tasks,
            daemonVerbosity = verbosity
          }
