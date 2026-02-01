module R2.Peer.Routing (routeTo, routeToError, routedFrom, handleR2Msg, runOverlayLookupChan) where

import Control.Monad.Extra
import Data.ByteString (ByteString)
import Polysemy
import Polysemy.Async
import Polysemy.Fail
import Polysemy.Transport
import R2
import R2.Bus
import R2.Encoding
import R2.Peer.MakeNode
import R2.Peer.Proto

routeTo ::
  ( Member (Bus chan ByteString) r,
    Member (Output ByteString) r,
    Member (LookupChan EstablishedConnection (Outbound chan)) r
  ) =>
  Address ->
  RouteTo Base64Text ->
  Sem r ()
routeTo = r2 \routeToAddr routedFrom -> do
  mChan <- lookupChan (EstablishedConnection routeToAddr)
  case mChan of
    Just (Outbound chan) -> busChan chan $ putChan (Just $ encodeStrict $ MsgRoutedFrom routedFrom)
    Nothing -> output $ encodeStrict $ MsgRouteToErr @Base64Text $ RouteToErr routeToAddr "unreachable"

routeToError ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (Inbound chan)) r
  ) =>
  RouteToErr ->
  Sem r ()
routeToError (RouteToErr addr _) = do
  mChan <- lookupChan (EstablishedConnection addr)
  whenJust mChan \(Inbound chan) -> busChan chan (putChan Nothing)

routedFrom ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan OverlayConnection (Inbound chan)) r,
    Member Fail r
  ) =>
  RoutedFrom Base64Text ->
  Sem r ()
routedFrom (RoutedFrom routedFromNode routedFromData) = do
  Inbound chan <- lookupChan (OverlayConnection routedFromNode)
  decoded <- base64ToBsSem routedFromData
  busChan chan $ putChan (Just decoded)

runOverlayLookupChan ::
  ( Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (Bus chan ByteString) r,
    Member (MakeNode chan) r,
    Member Fail r,
    Member Async r
  ) =>
  Address ->
  InterpreterFor (LookupChan OverlayConnection (Inbound chan)) r
runOverlayLookupChan router = interpretLookupChanSem \(OverlayConnection addr) -> do
  mStoredChan <- lookupChan (EstablishedConnection addr)
  Inbound <$> case mStoredChan of
    Just Bidirectional {inboundChan} -> pure inboundChan
    Nothing -> do
      Just (Bidirectional {outboundChan = Outbound -> routerOutboundChan}) <- lookupChan (EstablishedConnection router)
      inboundChan <$> makeR2ConnectedNode addr router routerOutboundChan

handleR2Msg ::
  ( Member (Bus chan ByteString) r,
    Member (LookupChan EstablishedConnection (Bidirectional chan)) r,
    Member (LookupChan OverlayConnection (Inbound chan)) r,
    Member (Output ByteString) r,
    Member Fail r
  ) =>
  Address ->
  R2Message Base64Text ->
  Sem r ()
handleR2Msg connAddr (MsgRouteTo msg) = reinterpretLookupChan (fmap $ Outbound . outboundChan) $ routeTo connAddr msg
handleR2Msg _ (MsgRouteToErr msg) = reinterpretLookupChan (fmap $ Inbound . inboundChan) $ routeToError msg
handleR2Msg _ (MsgRoutedFrom msg) = routedFrom msg
