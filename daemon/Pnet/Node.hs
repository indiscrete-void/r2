module Pnet.Node
  ( NodeToNodeMessage (..),
    pnetnd,
    mn2nn,
  )
where

import Data.Serialize
import GHC.Generics
import Pnet
import Polysemy hiding (send)
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Output
import Polysemy.Serialize
import Polysemy.Socket
import Polysemy.Trace
import Polysemy.Transport
import Transport.Maybe

data NodeToNodeMessage where
  Ping :: NodeToNodeMessage
  Pong :: NodeToNodeMessage
  deriving stock (Show, Generic)

mn2nn :: (Member (InputWithEOF ManagerToNodeMessage) r, Member (Output NodeToManagerMessage) r, Member Decoder r, Member Fail r) => InterpretersFor (InputWithEOF NodeToNodeMessage ': Output NodeToNodeMessage ': '[]) r
mn2nn = o2o . i2i
  where
    i2i :: (Member (InputWithEOF ManagerToNodeMessage) r, Member Decoder r, Member Fail r) => InterpreterFor (InputWithEOF NodeToNodeMessage) r
    i2i = interpret \Input ->
      let managerNodeData (ManagerNodeData (TunnelMessage maybeStr)) = maybeStr
          managerNodeData _ = _
       in Just <$> deserializeFrom (inputOrFail >>= maybeFailEOF . managerNodeData)
    o2o :: (Member (Output NodeToManagerMessage) r) => InterpreterFor (Output NodeToNodeMessage) r
    o2o = interpret \(Output msg) -> output . DaemonNodeData . TunnelMessage . Just $ serialize msg

pnetnd :: (Members (SocketEffects NodeToNodeMessage NodeToNodeMessage) r, Member Trace r) => Sem r ()
pnetnd = trace "sending Ping" >> output Ping >> handle go >> close
  where
    go Ping = traceTagged "Ping" "Pong" >> output Pong
    go Pong = traceTagged "Pong" "doing nothing"

instance Serialize NodeToNodeMessage
