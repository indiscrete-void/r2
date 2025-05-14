module R2.Options (Options (..), Transport (..), parse) where

import Data.List.Extra
import Options.Applicative
import R2
import R2.Client
import R2.Options.Parse
import R2.Routing

data Options = Options Command (Maybe FilePath)

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Mananges r2 daemon, creates bidirectional link between it and the outer world"
        <> header "Pandora Network manager"
    )

opts :: Parser Options
opts =
  Options
    <$> commandOpts
    <*> optional (strOption $ long "socket" <> short 's')

commandOpts :: Parser Command
commandOpts =
  Command
    <$> many (option address $ long "target" <> short 't')
    <*> hsubparser
      ( command "ls" (info lsOpts $ progDesc "List nodes connected to daemon")
          <> command "connect" (info connectOpts $ progDesc "Introduce a new node to daemon")
          <> command "tunnel" (info tunnelOpts $ progDesc "Provide transport for application layer")
      )

lsOpts :: Parser Action
lsOpts = pure Ls

connectOpts :: Parser Action
connectOpts = Connect <$> argument transport (metavar "TRANSPORT") <*> optional (option address $ long "node" <> short 'n')

tunnelOpts :: Parser Action
tunnelOpts = Tunnel <$> argument transport (metavar "TRANSPORT")
