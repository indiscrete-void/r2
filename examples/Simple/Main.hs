import Data.ByteString.Char8 qualified as BC
import Options.Applicative
import Polysemy
import Polysemy.Trace
import Polysemy.Transport
import R2.Client
import R2.DSL
import R2.Options
import R2.Peer.Proto (ProcessTransport (Stdio))

newtype Options = Options Verbosity

parse :: IO Options
parse = execParser parserInfo

parserInfo :: ParserInfo Options
parserInfo =
  info
    (helper <*> opts)
    ( fullDesc
        <> progDesc "DSL demo"
        <> header "Route-to network"
    )

opts :: Parser Options
opts = Options <$> verbosity

pana :: NetworkNode
pana = node "pana"

bob :: NetworkNode
bob = node "bob"

carl :: NetworkNode
carl = node "carl"

catnet :: (Members (NetworkEffects msgChan stdioChan) r) => Sem r ()
catnet = do
  Network {conn, conn_} <-
    mkNet $
      static
        { serve =
            [ (bob, exec "cat")
            ],
          link =
            [ (pana, carl),
              (carl, bob)
            ]
        }

  conn_ [pana] Ls
  conn_ [pana, carl] Ls
  conn_ [pana, carl, bob] Ls

  let panaMsgViaCarl = "pana greets bob"
  bobRes <- conn [pana, carl, bob] (Tunnel Stdio) $ do
    output (BC.pack panaMsgViaCarl)
    echo <- BC.unpack <$> inputOrFail
    close
    pure echo
  trace bobRes

main :: IO ()
main = do
  Options verbosity <- parse
  dslToIO verbosity catnet

{-
panaDaemon = do
  Network {conn} <-
    (mkDaemon pana)
      daemonConfig
        { peers =
            [ socat carl "tcp:example.com:47210",
              carl :/> bob
            ]
        }

  let panaMsgViaCarl = "pana greets bob"
  bobRes <- conn bob $ printf "echo %s" panaMsgViaCarl
  assertEq bobRes panaMsgViaCarl

simpleDaemon = await =<< mkDaemon me daemonConfig {peers = [carl]}
  where
    me = node "pana"
-}
