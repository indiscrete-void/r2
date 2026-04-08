|||
||| A device for network-wide datagram delivery
|||
||| Neighbor peers are reached by local resources
||| while faraway endpoints are reached by source-routing
|||
||| Source-routing is done by error-aware r2 protocol
||| Core: `r2 from (RouteTo to a) = SendTo to (RoutedFrom from a)`
||| (see `Router.Router.Msg` for more details)
|||
||| Direct messaging is done by finding local path with
||| longest matching prefix in a configurable table
|||
||| Example:
||| ```
||| router <- Router.new
||| exec router $ AddRoute ("ws" /> "alice")
||| exec router $ Send ("ws" /> "alice") "hello!" -- sent trough local websocket
||| exec router $ Send ("ws" /> "alice" /> "bob") "hello!" -- source-routed through neighbor alice
||| ```
|||
||| User is responsible for providing external connectivity
||| as well as decoding messages to Router.Msg and back
|||
module Aura.Router

import Aura.Addr
import Aura.PubSub
import Aura.Device
import Data.SortedMap as SMap
import Data.List1
import Data.IORef
import JSON.Derive

%language ElabReflection

public export
record RouteTo a where
    constructor MkRouteTo
    addr : NetworkAddr
    value : a

%runElab derive "RouteTo" [Show,Eq,ToJSON,FromJSON]

export
implementation Functor RouteTo where
    map f (MkRouteTo addr value) = MkRouteTo addr (f value)

public export
record RouteToErr where
    constructor MkRouteToErr
    addr : NetworkAddr
    err : String

%runElab derive "RouteToErr" [Show,Eq,ToJSON,FromJSON]

public export
record RoutedFrom a where
    constructor MkRoutedFrom
    addr : NetworkAddr
    value : a

%runElab derive "RoutedFrom" [Show,Eq,ToJSON,FromJSON]

export
implementation Functor RoutedFrom where
    map f (MkRoutedFrom addr value) = MkRoutedFrom addr (f value)

public export
data SendTo addr a = MkSendTo addr a

public export
data SendResult = MkSent
                | MkSendError String

public export
SendM : (Type -> Type) -> Type -> Type
SendM m a = a -> m SendResult

namespace Router
    public export
    data Msg a = MsgRouteTo (RouteTo (Router.Msg a))
               | MsgRoutedFrom (RoutedFrom (Router.Msg a))
               | MsgRouteToErr RouteToErr
               | MsgData a

    %runElab derive "Router.Msg" [Show,Eq,ToJSON,FromJSON]

    public export
    record Route m a where
        constructor MkRoute
        nextHop : NetworkAddr
        sendNextHop : SendM m (Router.Msg a)
        extraHops : List NameAddr

    export
    implementation Functor Msg where
        map f (MsgRouteTo msg) = MsgRouteTo $ map f <$> msg
        map f (MsgRoutedFrom msg) = MsgRoutedFrom $ map f <$> msg
        map _ (MsgRouteToErr msg) = MsgRouteToErr msg
        map f (MsgData a) = MsgData $ f a

    public export
    data Cmd : (Type -> Type) -> Type -> Type where
        Send : NetworkAddr -> a -> Cmd m a
        Handle : NetworkAddr -> Router.Msg a -> Cmd m a
        AddRoute : NetworkAddr -> SendM m (Router.Msg a) -> Cmd m a
        RemoveRoute : NetworkAddr -> Cmd m a

    public export
    data Event a = Recv NetworkAddr a | Error NetworkAddr String

    %runElab derive "Router.Event" [Show,Eq,ToJSON,FromJSON]

    public export
    Device : (m : Type -> Type) -> (a : Type) -> Type
    Device m a = Device.Device m (Router.Event a) (Router.Cmd m a)

    Table : (m : Type -> Type) -> (a : Type) -> Type
    Table m a = SortedMap NetworkAddr (SendM m (Router.Msg a))

    findRoute : Applicative m => NetworkAddr -> Router.Table m a -> Maybe (Route m a)
    findRoute addr table = go [] addr where
        go : List NameAddr -> NetworkAddr -> Maybe (Route m a)
        go hopsAcc router =
            case SMap.lookup router table of
                Just sendM => pure $ MkRoute {nextHop=router, sendNextHop=sendM, extraHops=hopsAcc}
                Nothing =>
                    let nextPrefix = netAddrToList router
                     in case List1.fromList (List1.init nextPrefix) of
                            Just ini => go (List1.last nextPrefix :: hopsAcc) (listToNetAddr ini)
                            Nothing => Nothing

    sendToRoute : Route m a -> SendM m (Router.Msg a)
    sendToRoute route msg = route.sendNextHop $ mkSourceRoutedMsg route.extraHops msg
      where
        mkSourceRoutedMsg : List NameAddr -> Router.Msg a' -> Router.Msg a'
        mkSourceRoutedMsg hops msg = case listToNetAddr <$> List1.fromList hops of
                                Just nextAddr => MsgRouteTo $ MkRouteTo nextAddr msg
                                Nothing => msg

    sendToAddr : HasIO io => IORef.IORef (Router.Table io a) -> NetworkAddr -> SendM io (Router.Msg a)
    sendToAddr tableRef addr msg = do
        table <- readIORef tableRef
        case findRoute addr table of
            Just route => sendToRoute route msg
            Nothing => pure $ MkSendError "unreachable"

    handleSrcRouting :
        HasIO io =>
        IORef.IORef (Router.Table io a) ->
        IORef.IORef (PubSub io (Router.Event a)) ->
        NetworkAddr ->
        Router.Msg a ->
        io ()
    handleSrcRouting tableRef _ rtr (MsgRouteTo (MkRouteTo dst msg)) = do
        let out = MsgRoutedFrom $ MkRoutedFrom rtr msg
        case !(sendToAddr tableRef dst out) of
            MkSendError err => do
                let errOut = MsgRouteToErr $ MkRouteToErr dst err
                ignore $ sendToAddr tableRef rtr errOut
            MkSent => pure ()
    handleSrcRouting tableRef eventsRef rtr (MsgRoutedFrom (MkRoutedFrom src msg)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        handleSrcRouting tableRef eventsRef srcNetAddr msg
    handleSrcRouting _ eventsRef rtr (MsgRouteToErr (MkRouteToErr src err)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        pubIORef eventsRef (Router.Error srcNetAddr err)
    handleSrcRouting _ eventsRef rtr (MsgData a) = do
        pubIORef eventsRef (Router.Recv rtr a)

    export
    new : HasIO io => io (Router.Device io a)
    new = do
        eventsRef <- newIORef emptyPubSub
        tableRef <- newIORef SMap.empty
        pure $ MkDevice eventsRef $ \case
            Send addr a => ignore $ sendToAddr tableRef addr (MsgData a)
            Handle addr msg => Router.handleSrcRouting tableRef eventsRef addr msg
            AddRoute name route => modifyIORef tableRef (SMap.insert name route)
            RemoveRoute name => modifyIORef tableRef (SMap.delete name)
