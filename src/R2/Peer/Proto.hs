module R2.Peer.Proto
  ( Raw (..),
    Self (..),
    ProcessTransport (..),
    R2Message (..),
    ClientToDaemonMessage (..),
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

newtype Raw = Raw {unRaw :: ByteString}
  deriving stock (Eq, Show, Generic)

instance ToJSON Raw where
  toJSON (Raw bs) = Value.String $ Text.pack $ BC.unpack bs

instance FromJSON Raw where
  parseJSON (Value.String txt) = return $ Raw $ BC.pack $ Text.unpack txt
  parseJSON _ = fail "Expected a string value"

newtype Self = Self {unSelf :: Address}
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonRemovePrefix "un") ''Self)

data R2Message msg where
  MsgRouteTo :: RouteTo msg -> R2Message msg
  MsgRouteToErr :: RouteToErr -> R2Message msg
  MsgRoutedFrom :: RoutedFrom msg -> R2Message msg
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''R2Message)

data ClientToDaemonMessage where
  ReqConnectNode :: ProcessTransport -> Maybe Address -> ClientToDaemonMessage
  ReqTunnelProcess :: ClientToDaemonMessage
  ReqListNodes :: ClientToDaemonMessage
  MsgExit :: ClientToDaemonMessage
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''ClientToDaemonMessage)

data DaemonToClientMessage where
  ResTunnelProcess :: Address -> DaemonToClientMessage
  ResNodeList :: [Address] -> DaemonToClientMessage
  deriving stock (Eq, Show, Generic)

$(deriveJSON aesonOptions ''DaemonToClientMessage)
