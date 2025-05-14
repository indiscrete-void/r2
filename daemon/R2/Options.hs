module R2.Options (Options (..), parse) where

import Options.Applicative
import R2.Options.Parse
import R2.Routing

data Options = Options (Maybe FilePath) Bool Address String

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Communicates with the network via managers connected to it"
        <> header "Pandora Network daemon"
    )

opts :: Parser Options
opts =
  Options
    <$> optional (strOption $ long "socket" <> short 's')
    <*> flag False True (long "daemon" <> short 'd')
    <*> argument address (metavar "ADDRESS")
    <*> argument str (metavar "CMD")
