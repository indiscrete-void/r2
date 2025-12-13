module R2.DSL where

import Control.Monad
import Data.List qualified as List
import Data.Map ((!))
import Data.Map qualified as Map
import Polysemy
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace (traceToStderrBuffered)
import Polysemy.Internal.Kind
import Polysemy.Process qualified as Sem
import Polysemy.Scoped
import Polysemy.Transport
import R2
import R2.Bus
import R2.Daemon
import R2.Daemon.Node
import R2.Peer
import System.Process.Extra

newtype NetworkNode = NetworkNode
  { nodeId :: Address
  }
  deriving stock (Eq, Ord)

data NetworkRoute
  = Node NetworkNode
  | NetworkRoute :/> NetworkRoute
  deriving stock (Eq, Ord)

newtype Service = ServiceCommand String

exec :: String -> Service
exec = ServiceCommand

data NetworkDescription = NetworkDescription
  { serve :: [(NetworkNode, Service)],
    link :: [(NetworkNode, NetworkNode)]
  }

static :: NetworkDescription
static = NetworkDescription {serve = [], link = []}

data Network r = Network
  { join :: Sem r (),
    conn :: forall a. NetworkRoute -> Sem (Append (Transport String String) r) a -> Sem r a
  }

node :: Address -> NetworkNode
node = NetworkNode

mkNet ::
  ( Member (Scoped CreateProcess Sem.Process) r,
    Member Async r,
    Member (Bus chan Message) r
  ) =>
  NetworkDescription ->
  Sem r (Network r)
mkNet NetworkDescription {..} = do
  let linkNodes = List.nub $ concat [[a, b] | (a, b) <- link]
  let serveMap = Map.fromList serve
  forM_ linkNodes \node@NetworkNode {nodeId} -> do
    let (ServiceCommand serviceA) = serveMap ! node
    async_ $
      r2nd serviceA $
        Connection
          { connAddr = nodeId,
            connChan = chan,
            connTransport = Socket
          }
    

  forM_ link $ \(a, b) -> do
    chan <- makeBidirectionalChan
    let (ServiceCommand serviceA) = serveMap ! a
    async_ $
      r2nd serviceA $
        Connection
          { connAddr = nodeId b,
            connChan = chan,
            connTransport = Socket
          }
    let (ServiceCommand serviceB) = serveMap ! b
    async_ $
      r2nd serviceB $
        Connection
          { connAddr = nodeId a,
            connChan = chan,
            connTransport = Socket
          }
  _

dslToIO = runFinal . embedToFinal @IO . traceToStderrBuffered
