module R2.Peer.Log (Log (..), logToTrace, ioToLog, ioToNodeChanLogged) where

import Control.Monad
import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Extra.Trace
import Polysemy.Internal.Kind
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Bus
import R2.Options
import R2.Peer.Conn
import Text.Printf (printf)

data Log where
  LogConnected :: Node chan -> Log
  LogRecv :: NetworkAddrSet -> Maybe ByteString -> Log
  LogSend :: NetworkAddrSet -> Maybe ByteString -> Log
  LogDisconnected :: NetworkAddrSet -> Log
  LogError :: NetworkAddrSet -> String -> Log

logToTrace :: (Member Trace r) => Verbosity -> InterpreterFor (Output Log) r
logToTrace verbosity = runOutputSem go
  where
    go (LogConnected node) = case node of
      ConnectedNode Connection {connAddrSet, connTransport} -> trace $ printf "connection established with %s over %s" (show connAddrSet) (show connTransport)
      AcceptedNode NewConnection {newConnTransport, newConnAddrSet} -> trace $ printf "accepted %s over %s" (show newConnAddrSet) (show newConnTransport)
    go (LogRecv addr msg) = traceTagged (printf "<-%s" $ show addr) $ when (verbosity > 0) $ trace (show msg)
    go (LogSend addr msg) = traceTagged (printf "->%s" $ show addr) $ when (verbosity > 1) $ trace (show msg)
    go (LogDisconnected addr) = trace $ printf "%s disconnected" $ show addr
    go (LogError addr err) = trace $ printf "%s error: %s" (show addr) err

logOut :: (Member (OutputWithEOF ByteString) r, Member (Output Log) r) => NetworkAddrSet -> Sem r a -> Sem r a
logOut addrSet =
  intercept @(OutputWithEOF ByteString)
    ( \(Output o) ->
        output (LogSend addrSet o) >> output o
    )

logIn :: (Member (InputWithEOF ByteString) r, Member (Output Log) r) => NetworkAddrSet -> Sem r a -> Sem r a
logIn addrSet =
  intercept @(InputWithEOF ByteString)
    ( \Input ->
        input >>= \i -> output (LogRecv addrSet i) >> pure i
    )

ioToLog :: (Member (Output Log) r) => NetworkAddrSet -> Sem (Append ByteTransport r) a -> Sem (Append ByteTransport r) a
ioToLog addrSet = logOut addrSet . logIn addrSet

ioToNodeChanLogged :: (Member (Bus chan ByteString) r, Member (Output Log) r) => NetworkAddrSet -> Bidirectional chan -> InterpretersFor ByteTransport r
ioToNodeChanLogged addrSet chan = ioToChan chan . ioToLog addrSet
