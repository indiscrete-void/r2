module Router

import Addr
import PubSub
import Device
import Data.IORef
import Data.List1
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

namespace Router
    public export
    data Msg a = MsgRouteTo (RouteTo a) | MsgRouteToErr RouteToErr | MsgRoutedFrom (RoutedFrom a)

    %runElab derive "Router.Msg" [Show,Eq,ToJSON,FromJSON]

    export
    implementation Functor Msg where
        map f (MsgRouteTo msg) = MsgRouteTo $ f <$> msg
        map f (MsgRoutedFrom msg) = MsgRoutedFrom $ f <$> msg
        map _ (MsgRouteToErr msg) = MsgRouteToErr msg

    public export
    data Cmd a = Send NetworkAddr a | Handle NetworkAddr (Router.Msg a)

    %runElab derive "Router.Cmd" [Show,Eq,ToJSON,FromJSON]

    public export
    data Event a = Recv NetworkAddr a | Error NetworkAddr String

    %runElab derive "Router.Event" [Show,Eq,ToJSON,FromJSON]

    public export
    data Output a = MkOutput a | MkControlOutput (Router.Msg (Router.Output a))

    %runElab derive "Router.Output" [Show,Eq,ToJSON,FromJSON]

    export
    Device : (m : Type -> Type) -> (a : Type) -> Type
    Device m a = Device.Device m (Router.Event a) (Router.Cmd a)

    unliftSendTo : SendTo NetworkAddr (Router.Output a) -> SendTo NameAddr (Router.Output a)
    unliftSendTo (MkSendTo addr a) = case netAddrToList addr of
        (nameAddr ::: []) => MkSendTo nameAddr a
        (router ::: hops) => MkSendTo router (hopsToOutputLayers hops a)
        where
            hopsToOutputLayers : List NameAddr -> Router.Output a' -> Router.Output a'
            hopsToOutputLayers (hop :: hops) a = MkControlOutput (MsgRouteTo $ MkRouteTo (MkNetworkNameAddr hop) $ hopsToOutputLayers hops a)
            hopsToOutputLayers [] a = a

    liftSendTo : HasIO io => (SendTo NameAddr (Router.Output a) -> io SendResult) -> SendTo NetworkAddr (Router.Output a) -> io SendResult
    liftSendTo ioSendTo req = ioSendTo $ unliftSendTo req

    handle :
        HasIO io =>
        (SendTo NetworkAddr (Router.Output a) -> io SendResult) ->
        Data.IORef.IORef (PubSub io (Router.Event a)) ->
        NetworkAddr ->
        Router.Msg a ->
        io ()
    handle sendToNet _ rtr (MsgRouteTo (MkRouteTo dst a)) = do
        case !(sendToNet (MkSendTo dst $ MkControlOutput $ MsgRoutedFrom $ MkRoutedFrom rtr $ MkOutput a)) of
            MkSendError err => ignore $ sendToNet (MkSendTo rtr $ MkControlOutput $ MsgRouteToErr $ MkRouteToErr dst err)
            MkSent => pure ()
    handle _ eventsRef rtr (MsgRoutedFrom (MkRoutedFrom src a)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        pubIORef eventsRef (Router.Recv srcNetAddr a)
    handle _ eventsRef rtr (MsgRouteToErr (MkRouteToErr src err)) = do
        let srcNetAddr = MkNetworkRoutedAddr (MkRoutedAddr rtr src)
        pubIORef eventsRef (Router.Error srcNetAddr err)

    export
    new : HasIO io => (SendTo NameAddr (Router.Output a) -> io SendResult) -> io (Router.Device io a)
    new sendToName = do
        eventsRef <- newIORef emptyPubSub
        let sendToNet = liftSendTo sendToName
        pure $ MkDevice eventsRef $ \case
            Send addr a => ignore $ sendToNet $ MkSendTo addr (MkOutput a)
            Handle addr msg => Router.handle sendToNet eventsRef addr msg
