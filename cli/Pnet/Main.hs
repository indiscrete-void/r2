{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString
import Data.ByteString.Char8 qualified as BC
import Network.Socket hiding (close)
import Pnet
import Pnet.Polysemy.Trace
import Polysemy hiding (run)
import Polysemy.Close
import Polysemy.Fail
import Polysemy.Input
import Polysemy.Output
import Polysemy.Trace
import Polysemy.Transport
import System.IO
import Transport.Maybe

pnet :: (Member ByteInputWithEOF r, Member ByteOutput r, Member Close r, Member Fail r, Member Trace r) => Sem r ()
pnet = do
  traceTagged "client -> server" (BC.unpack msg)
  output @ByteString msg
  recvdMsg <- maybeFail "EOF" =<< input
  traceTagged "server -> client" (BC.unpack recvdMsg)
  close
  where
    msg = "Hello, World!"

main :: IO ()
main =
  let run h = runM . inputToIO bufferSize h . outputToIO h . closeToIO h . failToEmbed @IO . traceToStderr
   in withPnetSocket \sock -> do
        connect sock =<< pnetSocketAddr
        h <- socketToHandle sock ReadWriteMode
        run h pnet
