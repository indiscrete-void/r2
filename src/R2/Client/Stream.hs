module R2.Client.Stream where

import Data.ByteString (ByteString)
import Network.Socket qualified as IO
import Polysemy
import Polysemy.Tagged
import Polysemy.Trace
import Polysemy.Transport
import R2.Bus
import R2.Socket
import System.IO

data ClientStream = ProcStream | ServerStream

type Stream stream =
  '[ Tagged stream ByteInputWithEOF,
     Tagged stream ByteOutputWithEOF
   ]

ioToStream :: forall stream r. (Members ByteTransport r) => InterpretersFor (Stream stream) r
ioToStream =
  (subsume . untag @stream @ByteOutputWithEOF)
    . (subsume . untag @stream @ByteInputWithEOF)

streamToChan :: forall stream chan r. (Member (Bus chan ByteString) r) => Bidirectional chan -> InterpretersFor (Stream stream) r
streamToChan Bidirectional {..} =
    (outputToBusChan outboundChan . untag @stream)
    . (inputToBusChan inboundChan . untag @stream)

procStreamToStdio :: (Member (Embed IO) r) => Int -> InterpretersFor (Stream 'ProcStream) r
procStreamToStdio bufferSize =
    (outputToIO stdout . untag @'ProcStream)
    . (inputToIO bufferSize stdin . untag @'ProcStream)

serverStreamToSocket :: (Member (Embed IO) r, Member Trace r) => Int -> IO.Socket -> InterpretersFor (Stream 'ServerStream) r
serverStreamToSocket bufferSize s =
  (outputToSocket s . untag @'ServerStream @ByteOutputWithEOF)
    . (inputToSocket bufferSize s . untag @'ServerStream @ByteInputWithEOF)
