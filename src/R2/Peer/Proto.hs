module R2.Peer.Proto
  ( Raw (..),
    Self (..),
    ConnTransport (..),
    ProcessTransport (..),
    R2Message (..),
    ClientToDaemonMessage (..),
    DaemonPeerInfo (..),
    DaemonToClientMessage (..),
  )
where

import Data.Aeson
import Data.Aeson qualified as Value
import Data.Aeson.TH
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as Text
import GHC.Generics
import R2
import Serial.Aeson.Options

data ProcessTransport
  = Stdio
  | Process String
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''ProcessTransport)

data ConnTransport = Overlay | Pipe ProcessTransport | Socket
  deriving stock (Eq, Show)

$(deriveJSON aesonOptions ''ConnTransport)

newtype Raw = Raw {unRaw :: ByteString}
  deriving stock (Eq, Show, Generic)

instance ToJSON Raw where
  toJSON (Raw bs) = Value.String $ Text.pack $ BC.unpack bs

instance FromJSON Raw where
  parseJSON (Value.String txt) = return $ Raw $ BC.pack $ Text.unpack txt
  parseJSON _ = fail "Expected a string value"

newtype Self = Self {unSelf :: NameAddr}
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonRemovePrefix "un") ''Self)

data R2Message msg where
  MsgRouteTo :: RouteTo (Maybe msg) -> R2Message msg
  MsgRouteToErr :: RouteToErr -> R2Message msg
  MsgRoutedFrom :: RoutedFrom (Maybe msg) -> R2Message msg
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''R2Message)

data ClientToDaemonMessage where
  ReqConnectNode :: ProcessTransport -> NameAddr -> ClientToDaemonMessage
  ReqTunnelProcess :: ClientToDaemonMessage
  ReqListNodes :: ClientToDaemonMessage
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''ClientToDaemonMessage)

data DaemonPeerInfo = DaemonPeerInfo
  { daemonPeerAddr :: NetworkAddrSet,
    daemonPeerTransport :: ConnTransport
  }
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''DaemonPeerInfo)

data DaemonToClientMessage where
  ResTunnelProcess :: NameAddr -> DaemonToClientMessage
  ResNodeList :: [DaemonPeerInfo] -> DaemonToClientMessage
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''DaemonToClientMessage)
