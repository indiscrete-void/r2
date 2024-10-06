module Pnet.Routing.Transfer where

import Data.ByteString (ByteString)
import Pnet
import Pnet.Routing
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Process
import Polysemy.Scoped
import Polysemy.Trace
import Polysemy.Transport
import System.Process.Extra

streamIO :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r) => Sem r ()
streamIO = async_ nodeToIO >> ioToNode
  where
    ioToNode = handle $ output . RoutedFrom defaultAddr
    nodeToIO = handle $ r2Sem (const $ output . routedFromData) defaultAddr

streamTransport :: (Member Async r, Members (TransportEffects ByteString ByteString) r, Member (InputWithEOF (RouteTo ByteString)) r, Member (Output (RoutedFrom ByteString)) r, Member Trace r, Member (Scoped CreateProcess Process) r) => Transport -> Sem r ()
streamTransport Stdio = streamIO
streamTransport (Process cmd) = exec (shell cmd) streamIO
