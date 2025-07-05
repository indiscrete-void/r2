module Polysemy.Transport.Bus (RecvdFrom (..), AddRecvFrom, RecvFrom, SendTo, sendTo, recvdFrom, recvFrom) where

import Polysemy
import Polysemy.Input
import Polysemy.Output
import Polysemy.Scoped

data RecvdFrom addr i = RecvdFrom addr i

type AddRecvFrom addr i = Output (RecvdFrom addr i)

type RecvFrom addr i = Scoped addr (Input i)

type SendTo addr o = Scoped addr (Output o)

sendTo :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
sendTo = scoped

recvdFrom :: (Member (Output (RecvdFrom addr i)) r) => addr -> i -> Sem r ()
recvdFrom addr i = output $ RecvdFrom addr i

recvFrom :: (Member (SendTo addr o) r) => addr -> InterpreterFor (Output o) r
recvFrom = scoped
