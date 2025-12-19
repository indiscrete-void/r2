module R2.Daemon.Options (Options (..), parse) where

import Options.Applicative
import R2
import R2.Options
import R2.Peer

data Options = Options Verbosity (Maybe FilePath) Address String

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Communicates with the network via managers connected to it"
        <> header "Route-to network daemon"
    )

opts :: Parser Options
opts =
  Options
    <$> verbosity
    <*> optional (strOption $ long "socket" <> short 's')
    <*> argument address (metavar "ADDRESS")
    <*> argument str (metavar "CMD")
