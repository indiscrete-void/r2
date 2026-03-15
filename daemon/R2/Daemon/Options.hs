module R2.Daemon.Options (Options (..), parse) where

import Data.Set qualified as Set
import Options.Applicative
import R2
import R2.Options
import R2.Peer

data Options = Options Verbosity (Maybe FilePath) (AddrSet LabelAddr)

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
    <*> (addrSetFromList <$> some (argument labelAddrP (metavar "ADDRESS")))
