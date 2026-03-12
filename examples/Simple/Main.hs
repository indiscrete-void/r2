import Data.ByteString.Char8 qualified as BC
import Options.Applicative
import Polysemy.Trace
import Polysemy.Transport
import R2
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

lain :: NameAddr
lain = "lain"

spongebob :: NameAddr
spongebob = "spongebob"

carl :: NameAddr
carl = "carl"

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

    conn_ (NetworkNameAddr lain) Ls
    conn_ (NetworkNameAddr lain /> NetworkNameAddr carl) Ls
    conn_ (NetworkNameAddr lain /> NetworkNameAddr carl /> NetworkNameAddr spongebob) Ls

    let lainMsgViaCarl = "lain greets spongebob"
    spongebobRes <- conn (NetworkNameAddr lain /> NetworkNameAddr carl /> NetworkNameAddr spongebob) (Tunnel Stdio) $ do
      output (Just $ BC.pack lainMsgViaCarl)
      echo <- BC.unpack <$> inputOrFail
      output Nothing
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
