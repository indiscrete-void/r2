module ConnTab

import Addr
import Device
import PubSub
import Data.IORef
import Data.List

namespace ConnTab
    public export
    record Lease (m : Type -> Type) (a : Type) where
        constructor MkLease
        send : a -> m ()
        close : m ()

    public export
    data Cmd : (Type -> Type) -> Type -> Type where
        Open : NameAddr -> ConnTab.Lease m a -> Cmd m a
        Send : NameAddr -> a -> Cmd m a
        Close : NameAddr -> Cmd m a

    public export
    data Event : (Type -> Type) -> Type -> Type where
        Opened : NameAddr -> ConnTab.Lease m a -> Event m a
        Recv : NameAddr -> a -> Event m a
        Closed : NameAddr -> Event m a

    public export
    Device : (m : Type -> Type) -> (a : Type) -> Type
    Device m a = (Device.Device m (ConnTab.Event m a) (ConnTab.Cmd m a))

    public export
    record ConnTab (m : Type -> Type) (a : Type) where
        constructor MkConnTab
        antenna : Device.Device m (ConnTab.Event m a) (ConnTab.Cmd m a)
        table : IORef (List (NameAddr, ConnTab.Lease m a))

    export
    lookup : HasIO io => IORef (List (NameAddr, ConnTab.Lease io a)) -> NameAddr -> io (Maybe (ConnTab.Lease io a))
    lookup tabRef rAddr = do
        tab <- readIORef tabRef
        pure $ snd <$> List.find (\(lAddr, _) => lAddr == rAddr) tab

    exec : HasIO io =>
           IORef (List (NameAddr, ConnTab.Lease io a)) ->
           IORef (PubSub io (ConnTab.Event io a)) ->
           ConnTab.Cmd io a ->
           io ()
    exec tabRef eventsRef (Open addr ctrl) = do
        modifyIORef tabRef ((addr, ctrl) ::)
        pubIORef eventsRef $ ConnTab.Opened addr ctrl
    exec tabRef eventsRef (Send addr msg) = do
        mCtrl <- lookup tabRef addr
        whenJust mCtrl (\ctrl => send ctrl msg)
    exec tabRef eventsRef (Close addr) = do
        mCtrl <- lookup tabRef addr
        whenJust mCtrl close

    export
    new : HasIO io => io (ConnTab.ConnTab io a)
    new = do
        eventsRef <- newIORef emptyPubSub
        tabRef <- newIORef []
        pure $ MkConnTab
                { antenna = MkDevice eventsRef (exec tabRef eventsRef)
                , table = tabRef
                }
