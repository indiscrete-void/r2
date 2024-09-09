module Pnet.Options (Options (..), Transport (..), parse) where

import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Options.Applicative
import Pnet
import Pnet.Client
import Pnet.Routing
import Transport.Maybe

data Options = Options Command (Maybe FilePath)

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
    <*> optional (strOption $ long "socket" <> short 's')

lsOpts :: Parser Command
lsOpts = pure Ls

connectOpts :: Parser Command
connectOpts = Connect <$> argument transport (metavar "TRANSPORT") <*> optional (option address $ long "node" <> short 'n')

tunnelOpts :: Parser Command
tunnelOpts = Tunnel <$> argument address (metavar "ID") <*> argument transport (metavar "TRANSPORT")

transport :: ReadM Transport
transport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = str >>= maybeFail "invalid node ID" . parseNodeID
  where
    parseNodeID = fmap (fromInteger . bsToInteger) . decodeBase58 bitcoinAlphabet . BC.pack
