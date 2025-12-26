module R2.Manager.Options (Options (..), parse) where

import Data.Text qualified as Text
import Options.Applicative
import R2
import R2.DSL
import R2.Options
import R2.Peer
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
  { tomlDaemonAddress :: Address,
    tomlDaemonSocketPath :: Maybe FilePath
  }

data TOMLDaemonDescription = TOMLDaemonDescription
  { tomlDaemonSelf :: TOMLDaemonOptions,
    tomlDaemonLinks :: [TOMLDaemonConnection],
    tomlDaemonServices :: [TOMLDaemonConnection]
  }

data TOMLDaemonConnection = TOMLDaemonConnection
  { tomlDaemonConnProcess :: String,
    tomlDaemonConnAddress :: Maybe Address
  }

selfCodec :: TomlCodec TOMLDaemonOptions
selfCodec =
  TOMLDaemonOptions
    <$> Toml.diwrap (Toml.string "addr") .= tomlDaemonAddress
    <*> Toml.dioptional (Toml.string "socket") .= tomlDaemonSocketPath

connCodec :: TomlCodec TOMLDaemonConnection
connCodec =
  TOMLDaemonConnection
    <$> Toml.string "cmd" .= tomlDaemonConnProcess
    <*> Toml.dioptional (Toml.diwrap $ Toml.string "addr") .= tomlDaemonConnAddress

descriptionCodec :: TomlCodec TOMLDaemonDescription
descriptionCodec =
  TOMLDaemonDescription
    <$> Toml.table selfCodec "self" .= tomlDaemonSelf
    <*> Toml.list connCodec "conn" .= tomlDaemonLinks
    <*> Toml.list connCodec "serve" .= tomlDaemonServices

resolveTOMLConnections :: Verbosity -> FilePath -> [TOMLDaemonConnection] -> [DaemonConnection]
resolveTOMLConnections verbosity socketPath =
  map
    ( \(TOMLDaemonConnection {..}) ->
        DaemonConnection
          { daemonConnProcess =
              resolveConnectionCmd
                verbosity
                socketPath
                tomlDaemonConnAddress
                tomlDaemonConnProcess,
            daemonConnAddress = tomlDaemonConnAddress
          }
    )

parse :: IO DaemonDescription
parse = do
  Options verbosity configPath <- execParser parserInfo
  tomlRes <- Toml.decodeFileEither descriptionCodec configPath
  case tomlRes of
    Left errs -> fail $ Text.unpack $ Toml.prettyTomlDecodeErrors errs
    Right TOMLDaemonDescription {tomlDaemonSelf = TOMLDaemonOptions {..}, ..} -> do
      socketPath <- resolveSocketPath tomlDaemonSocketPath
      let links = resolveTOMLConnections verbosity socketPath tomlDaemonLinks
      let services = resolveTOMLConnections verbosity socketPath tomlDaemonServices
      pure $
        DaemonDescription
          { daemonAddress = tomlDaemonAddress,
            daemonSocketPath = socketPath,
            daemonLinks = links,
            daemonServices = services,
            daemonVerbosity = verbosity
          }
