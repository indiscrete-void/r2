module R2.Daemon (ConnTransport (..), NewConnection (..), Connection (..)) where

import R2
import R2.Daemon.Bus
import R2.Peer

data ConnTransport = R2 Address | Pipe Address ProcessTransport | Socket
  deriving stock (Eq, Show)

data NewConnection = NewConnection
  { newConnAddr :: Maybe Address,
    newConnTransport :: ConnTransport
  }

data Connection chan = Connection
  { connAddr :: Address,
    connTransport :: ConnTransport,
    connChan :: NodeBusChan chan
  }
  deriving stock (Eq, Show)
