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

lain :: NetworkNode
lain = node "lain"

spongebob :: NetworkNode
spongebob = node "spongebob"

carl :: NetworkNode
carl = node "carl"

catnet :: NetworkDescription
catnet =
  static
    { serve =
        [ (spongebob, exec "cat")
        ],
      link =
        [ (lain, carl),
          (carl, spongebob)
        ]
    }

main :: IO ()
main = do
  Options verbosity <- parse
  dslToIO verbosity (serve catnet) $ do
    Network {conn, conn_} <- mkNet catnet

    conn_ [lain] Ls
    conn_ [lain, carl] Ls
    conn_ [lain, carl, spongebob] Ls

    let lainMsgViaCarl = "lain greets spongebob"
    spongebobRes <- conn [lain, carl, spongebob] (Tunnel Stdio) $ do
      output (BC.pack lainMsgViaCarl)
      echo <- BC.unpack <$> inputOrFail
      close
      pure echo
    trace spongebobRes

{-
lainDaemon = do
  Network {conn} <-
    (mkDaemon lain)
      daemonConfig
        { peers =
            [ socat carl "tcp:example.com:47210",
              carl :/> spongebob
            ]
        }

  let lainMsgViaCarl = "lain greets spongebob"
  spongebobRes <- conn spongebob $ printf "echo %s" lainMsgViaCarl
  assertEq spongebobRes lainMsgViaCarl

simpleDaemon = await =<< mkDaemon me daemonConfig {peers = [carl]}
  where
    me = node "lain"
-}
