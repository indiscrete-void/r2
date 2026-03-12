module R2.Client.Options (Options (..), ProcessTransport (..), parse) where

import Data.Maybe
import Options.Applicative
import R2.Client
import R2.Options
import R2.Peer
import R2.Peer.Proto

data Options = Options Verbosity Command (Maybe FilePath)

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Mananges r2 daemon, creates bidirectional link between it and the outer world"
        <> header "Route-to network"
    )

opts :: Parser Options
opts =
  Options
    <$> verbosity
    <*> commandOpts
    <*> optional (strOption $ long "socket" <> short 's')

targetOpt :: Parser TargetAddr
targetOpt = option targetNetAddrP (long "target" <> short 't' <> value TargetAddrServer)

targetArg :: Parser TargetAddr
targetArg = argument targetNetAddrP (metavar "TARGET")

commandOpts :: Parser Command
commandOpts =
  hsubparser
    ( command "ls" (info lsOpts $ progDesc "List nodes connected to daemon")
        <> command "connect" (info connectOpts $ progDesc "Introduce a new node to daemon")
        <> command "open" (info openOpts $ progDesc "Provide transport for application layer")
        <> command "serve" (info serveOpts $ progDesc "Serve application layer command")
    )

lsOpts :: Parser Command
lsOpts = Command <$> targetOpt <*> pure Ls

connectOpts :: Parser Command
connectOpts = Command <$> targetOpt <*> (Connect <$> argument processTransport (metavar "TRANSPORT") <*> optional (option nameAddrP $ long "node" <> short 'n'))

openOpts :: Parser Command
openOpts = Command <$> targetArg <*> (Open <$> argument processTransport (metavar "TRANSPORT"))

serveOpts :: Parser Command
serveOpts = Command <$> targetOpt <*> (Serve <$> optional (option labelAddrP $ long "name" <> short 'n') <*> argument processTransport (metavar "TRANSPORT"))
