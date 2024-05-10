module Pnet.Options (Options (..), Transport (..), Command (..), parse) where

import Options.Applicative
import Pnet

newtype Options = Options Command

data Command
  = Ls
  | Connect !Transport !(Maybe String)
  | Tunnel !String !Transport

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "Mananges pnet daemon, creates bidirectional link between it and the outer world"
        <> header "Pandora Network manager"
    )

opts :: Parser Options
opts =
  Options
    <$> hsubparser
      ( command "ls" (info lsOpts $ progDesc "List nodes connected to daemon")
          <> command "connect" (info connectOpts $ progDesc "Introduce a new node to daemon")
          <> command "tunnel" (info tunnelOpts $ progDesc "Provide transport for application layer")
      )

lsOpts :: Parser Command
lsOpts = pure Ls

connectOpts :: Parser Command
connectOpts = Connect <$> argument transport (metavar "TRANSPORT") <*> optional (strOption $ long "node" <> short 'n')

tunnelOpts :: Parser Command
tunnelOpts = Tunnel <$> argument str (metavar "ID") <*> argument transport (metavar "TRANSPORT")

transport :: ReadM Transport
transport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg
