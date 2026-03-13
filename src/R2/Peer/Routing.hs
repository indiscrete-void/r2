module R2.Peer.Routing (LookupChan (..), EstablishedConnection (..), OverlayConnection (..), interpretLookupChanSem, routeTo, routeToError, routedFrom, handleR2Msg, makeR2ConnectedNode, runOverlayLookupChan) where

import Control.Applicative
import Control.Monad.Extra
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Maybe
import Data.ByteString (ByteString)
import Data.Set qualified as Set
import Polysemy
import Polysemy.Async
import Polysemy.Conc.Effect.Events
import Polysemy.Conc.Interpreter.Events
import Polysemy.Extra.Async
import Polysemy.Fail
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.Conn
import R2.Peer.Proto
import R2.Peer.Storage

type family AddressChan addr chan

data LookupChan addr chan m a where
  LookupChan :: addr -> LookupChan addr chan m (AddressChan addr chan)

makeSem ''LookupChan

newtype OverlayConnection = OverlayConnection NetworkAddr

type instance AddressChan OverlayConnection chan = chan

newtype EstablishedConnection = EstablishedConnection NetworkAddr

type instance AddressChan EstablishedConnection chan = Maybe chan

interpretLookupChanSem :: (addr -> Sem r (AddressChan addr chan)) -> InterpreterFor (LookupChan addr chan) r
interpretLookupChanSem f = interpret \(LookupChan addr) -> f addr

reinterpretLookupChan :: (Member (LookupChan addr chan) r) => (AddressChan addr chan -> AddressChan addr chan') -> InterpreterFor (LookupChan addr chan') r
reinterpretLookupChan f = interpretLookupChanSem (fmap f . lookupChan)

routeTo ::
  ( Member (Bus chan ByteString) r,
    Member (OutputWithEOF ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Outbound chan))) r
  ) =>
  NetworkAddr ->
  RouteTo (Maybe Base64Text) ->
  Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan (EstablishedConnection routeToAddr)
  case mChan of
    Just (HighLevel (Outbound chan)) -> busChan chan $ putChan (Just $ encodeStrict $ MsgRoutedFrom routedFrom)
    Nothing -> output $ Just $ encodeStrict $ MsgRouteToErr @Base64Text $ RouteToErr routeToAddr "unreachable"

routeToError ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Inbound chan))) r
  ) =>
  RouteToErr ->
  Sem r ()
routeToError (RouteToErr addr _) = do
  mChan <- lookupChan (EstablishedConnection addr)
  whenJust mChan \(HighLevel (Inbound chan)) -> busChan chan (putChan Nothing)

routedFrom ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan OverlayConnection (Inbound chan)) r,
    Member Fail r
  ) =>
  RoutedFrom (Maybe Base64Text) ->
  Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  decoded <- mapM base64ToBsSem routedFromData
  Inbound chan <- lookupChan (OverlayConnection routedFromNode)
  busChan chan $ putChan decoded

outboundChanToR2 :: (Member (Bus chan ByteString) r) => Outbound chan -> Outbound chan -> NetworkAddr -> Sem r ()
outboundChanToR2 (Outbound routerChan) (Outbound chan) addr = do
  mapEOF
    (busChan chan takeChan)
    (busChan routerChan . outputToChan . encodeOutput . output . Just . MsgRouteTo . RouteTo addr . fmap bsToBase64)

closeOnDisconnect ::
  ( Member (EventConsumer (Event chan)) r,
    Member (Bus chan ByteString) r
  ) =>
  chan ->
  NetworkAddrSet ->
  Sem r ()
chan `closeOnDisconnect` router = subscribe go
  where
    go =
      consume >>= \case
        ConnDestroyed destroyedAddr
          | destroyedAddr == router -> outputToBusChan chan (output Nothing)
        _ -> go

makeR2ConnectedNode ::
  ( Member (Bus chan ByteString) r,
    Member (Peer chan) r,
    Member Async r,
    Member (EventConsumer (Event chan)) r
  ) =>
  NetworkAddr ->
  NetworkAddrSet ->
  HighLevel (Outbound chan) ->
  Sem r (Connection chan)
makeR2ConnectedNode addr routerAddrSet (HighLevel routerOutboundChan) = do
  let routerDerivedAddrSet = routedAddrSet addr routerAddrSet
  let connAddrSet = singleAddrSet addr <> routerDerivedAddrSet
  chan@Bidirectional {inboundChan = clientInboundChan, outboundChan = Outbound -> clientOutboundChan} <- makeBidirectionalChan
  async_ $ clientInboundChan `closeOnDisconnect` routerAddrSet
  async_ $ outboundChanToR2 routerOutboundChan clientOutboundChan addr
  superviseNode connAddrSet Overlay chan

runOverlayLookupChan ::
  ( Member (Bus chan ByteString) r,
    Member (Storage chan) r,
    Member (Peer chan) r,
    Member Fail r,
    Member Async r,
    Member (EventConsumer (Event chan)) r
  ) =>
  NetworkAddrSet ->
  InterpreterFor (LookupChan OverlayConnection (Inbound chan)) r
runOverlayLookupChan routerAddrs = interpretLookupChanSem \(OverlayConnection addr) -> do
  mStoredNode <- storageLookupNode (singleAddrSet addr)
  Inbound <$> case mStoredNode of
    Just node -> pure $ inboundChan $ nodeChan node
    Nothing -> do
      Just (ConnectedNode Connection {connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan}) <- storageLookupNode routerAddrs
      inboundChan . connChan <$> makeR2ConnectedNode addr routerAddrs routerOutboundChan

handleR2Msg ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r,
    Member (OutputWithEOF ByteString) r,
    Member Fail r,
    Member (Peer chan) r,
    Member Async r,
    Member (Storage chan) r,
    Member (EventConsumer (Event chan)) r
  ) =>
  NetworkAddrSet ->
  R2Message Base64Text ->
  Sem r ()
handleR2Msg connAddrSet (MsgRouteTo msg) = do
  bestRepresentative <- maybe (fail "route-to received from node without addr") pure $ bestAddrSetRepresentative connAddrSet
  reinterpretLookupChan (fmap . fmap $ Outbound . outboundChan) $ routeTo bestRepresentative msg
handleR2Msg _ (MsgRouteToErr msg) = reinterpretLookupChan (fmap . fmap $ Inbound . inboundChan) $ routeToError msg
handleR2Msg connAddrSet (MsgRoutedFrom msg) = runOverlayLookupChan connAddrSet $ routedFrom msg
