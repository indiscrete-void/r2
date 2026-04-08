module Router

import Addr
import PubSub
import Device
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
    data Msg a = MsgRouteTo (RouteTo a) | MsgRouteToErr RouteToErr | MsgRoutedFrom (RoutedFrom a)

    %runElab derive "Router.Msg" [Show,Eq,ToJSON,FromJSON]

    public export
    data Output a = MkOutput a | MkControlOutput (Router.Msg (Router.Output a))

    %runElab derive "Router.Output" [Show,Eq,ToJSON,FromJSON]

    export
    implementation Functor Msg where
        map f (MsgRouteTo msg) = MsgRouteTo $ f <$> msg
        map f (MsgRoutedFrom msg) = MsgRoutedFrom $ f <$> msg
        map _ (MsgRouteToErr msg) = MsgRouteToErr msg

    public export
    data Cmd : (Type -> Type) -> Type -> Type where
        Send : NetworkAddr -> a -> Cmd m a
        Handle : NetworkAddr -> Router.Msg a -> Cmd m a
        AddRoute : NameAddr -> SendM m (Router.Output a) -> Cmd m a
        RemoveRoute : NameAddr -> Cmd m a

    public export
    data Event a = Recv NetworkAddr a | Error NetworkAddr String

    %runElab derive "Router.Event" [Show,Eq,ToJSON,FromJSON]

    public export
    Device : (m : Type -> Type) -> (a : Type) -> Type
    Device m a = Device.Device m (Router.Event a) (Router.Cmd m a)

    Table : (m : Type -> Type) -> (a : Type) -> Type
    Table m a = SortedMap NameAddr (SendM m (Router.Output a))

    sendToName : HasIO io => IORef.IORef (Router.Table io a) -> SendTo NameAddr (Router.Output a) -> io SendResult
    sendToName tableRef (MkSendTo name out) = do
        table <- readIORef tableRef
        case SMap.lookup name table of
            Just sendM => sendM out
            Nothing => pure $ MkSendError "unreachable"

    mkSrcRoutedOut : SendTo NetworkAddr (Router.Output a) -> SendTo NameAddr (Router.Output a)
    mkSrcRoutedOut (MkSendTo addr a) = case netAddrToList addr of
        (nameAddr ::: []) => MkSendTo nameAddr a
        (router ::: hops) => MkSendTo router (hopsToOutput hops a)
        where
            hopsToOutput : List NameAddr -> Router.Output a' -> Router.Output a'
            hopsToOutput (hop :: hops) a = MkControlOutput (MsgRouteTo $ MkRouteTo (MkNetworkNameAddr hop) $ hopsToOutput hops a)
            hopsToOutput [] a = a

    sendToNetSrcRouted :  HasIO io => IORef.IORef (Router.Table io a) -> SendTo NetworkAddr (Router.Output a) -> io SendResult
    sendToNetSrcRouted tableRef = sendToName tableRef . mkSrcRoutedOut

    handleSrcRouting :
        HasIO io =>
        IORef.IORef (Router.Table io a) ->
        IORef.IORef (PubSub io (Router.Event a)) ->
        NetworkAddr ->
        Router.Msg a ->
        io ()
    handleSrcRouting tableRef _ rtr (MsgRouteTo (MkRouteTo dst a)) = do
        let out = MkSendTo dst $ MkControlOutput $ MsgRoutedFrom $ MkRoutedFrom rtr $ MkOutput a
        case !(sendToNetSrcRouted tableRef out) of
            MkSendError err => do
                let errOut = MkSendTo rtr $ MkControlOutput $ MsgRouteToErr $ MkRouteToErr dst err
                ignore $ sendToNetSrcRouted tableRef errOut
            MkSent => pure ()
    handleSrcRouting _ eventsRef rtr (MsgRoutedFrom (MkRoutedFrom src a)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        pubIORef eventsRef (Router.Recv srcNetAddr a)
    handleSrcRouting _ eventsRef rtr (MsgRouteToErr (MkRouteToErr src err)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        pubIORef eventsRef (Router.Error srcNetAddr err)

    export
    new : HasIO io => io (Router.Device io a)
    new = do
        eventsRef <- newIORef emptyPubSub
        tableRef <- newIORef SMap.empty
        pure $ MkDevice eventsRef $ \case
            Send addr a => ignore $ sendToNetSrcRouted tableRef $ MkSendTo addr (MkOutput a)
            Handle addr msg => Router.handleSrcRouting tableRef eventsRef addr msg
            AddRoute name route => modifyIORef tableRef (SMap.insert name route)
            RemoveRoute name => modifyIORef tableRef (SMap.delete name)
