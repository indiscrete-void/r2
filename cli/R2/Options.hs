module R2.Options (Options (..), ProcessTransport (..), parse) where

import Options.Applicative
import R2.Peer
import R2.Peer.Client

data Options = Options Command (Maybe FilePath)

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
connectOpts = Connect <$> argument processTransport (metavar "TRANSPORT") <*> optional (option address $ long "node" <> short 'n')

tunnelOpts :: Parser Action
tunnelOpts = Tunnel <$> argument processTransport (metavar "TRANSPORT")
