module R2.Peer.Routing (LookupChan (..), EstablishedConnection (..), OverlayConnection (..), interpretLookupChanSem, routeTo, routeToError, routedFrom, handleR2Msg, makeR2ConnectedNode, runOverlayLookupChan) where

import Control.Monad.Extra
import Control.Monad.Loops
import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Async
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

newtype OverlayConnection = OverlayConnection Address

type instance AddressChan OverlayConnection chan = chan

newtype EstablishedConnection = EstablishedConnection Address

type instance AddressChan EstablishedConnection chan = Maybe chan

interpretLookupChanSem :: (addr -> Sem r (AddressChan addr chan)) -> InterpreterFor (LookupChan addr chan) r
interpretLookupChanSem f = interpret \(LookupChan addr) -> f addr

reinterpretLookupChan :: (Member (LookupChan addr chan) r) => (AddressChan addr chan -> AddressChan addr chan') -> InterpreterFor (LookupChan addr chan') r
reinterpretLookupChan f = interpretLookupChanSem (fmap f . lookupChan)

routeTo ::
  ( Member (Bus chan ByteString) r,
    Member (Output ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Outbound chan))) r
  ) =>
  Address ->
  RouteTo Base64Text ->
  Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan (EstablishedConnection routeToAddr)
  case mChan of
    Just (HighLevel (Outbound chan)) -> busChan chan $ putChan (Just $ encodeStrict $ MsgRoutedFrom routedFrom)
    Nothing -> output $ encodeStrict $ MsgRouteToErr @Base64Text $ RouteToErr routeToAddr "unreachable"

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
  RoutedFrom Base64Text ->
  Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  decoded <- base64ToBsSem routedFromData
  Inbound chan <- lookupChan (OverlayConnection routedFromNode)
  busChan chan $ putChan (Just decoded)

outboundChanToR2 :: (Member (Bus chan ByteString) r) => Outbound chan -> Outbound chan -> Address -> Sem r ()
outboundChanToR2 (Outbound routerChan) (Outbound chan) addr = do
  whileJust_
    (busChan chan takeChan)
    (busChan routerChan . outputToChan . encodeOutput . output . MsgRouteTo . RouteTo addr . bsToBase64)

makeR2ConnectedNode ::
  ( Member (Bus chan ByteString) r,
    Member (Peer chan) r,
    Member Async r
  ) =>
  Address ->
  Address ->
  HighLevel (Outbound chan) ->
  Sem r (Connection chan)
makeR2ConnectedNode addr router (HighLevel routerOutboundChan) = do
  chan@Bidirectional {outboundChan = Outbound -> clientOutboundChan} <- makeBidirectionalChan
  async_ $ outboundChanToR2 routerOutboundChan clientOutboundChan addr
  superviseNode (Just addr) (R2 router) chan

runOverlayLookupChan ::
  ( Member (Bus chan ByteString) r,
    Member (Storage chan) r,
    Member (Peer chan) r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  InterpreterFor (LookupChan OverlayConnection (Inbound chan)) r
runOverlayLookupChan router = interpretLookupChanSem \(OverlayConnection addr) -> do
  mStoredNode <- storageLookupNode addr
  Inbound <$> case mStoredNode of
    Just node -> pure $ inboundChan $ nodeChan node
    Nothing -> do
      Just (ConnectedNode Connection {connHighLevelChan = fmap (Outbound . outboundChan) -> routerOutboundChan}) <- storageLookupNode router
      inboundChan . connChan <$> makeR2ConnectedNode addr router routerOutboundChan

handleR2Msg ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (HighLevel (Bidirectional chan))) r,
    Member (Output ByteString) r,
    Member Fail r,
    Member (Peer chan) r,
    Member Async r,
    Member (Storage chan) r
  ) =>
  Address ->
  R2Message Base64Text ->
  Sem r ()
handleR2Msg connAddr (MsgRouteTo msg) = reinterpretLookupChan (fmap . fmap $ Outbound . outboundChan) $ routeTo connAddr msg
handleR2Msg _ (MsgRouteToErr msg) = reinterpretLookupChan (fmap . fmap $ Inbound . inboundChan) $ routeToError msg
handleR2Msg connAddr (MsgRoutedFrom msg) = runOverlayLookupChan connAddr $ routedFrom msg
