|||
||| A device for mapping "physical" connections to named addresses
||| i.e. Transport interface -> `Addr.NameAddr` conn
||| The device injects no protocol inside connections
|||
module ConnTab

import Addr
import Device
import PubSub
import Data.IORef
import Data.List
import Data.SortedMap as Map

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
    Table : (m : Type -> Type) -> (a : Type) -> Type
    Table m a = SortedMap NameAddr (ConnTab.Lease m a)

    public export
    record ConnTab (m : Type -> Type) (a : Type) where
        constructor MkConnTab
        device : Device.Device m (ConnTab.Event m a) (ConnTab.Cmd m a)
        table : IORef (Table m a)

    export
    lookup : HasIO io => IORef (ConnTab.Table io a) -> NameAddr -> io (Maybe (ConnTab.Lease io a))
    lookup tabRef addr = do
        tab <- readIORef tabRef
        pure $ Map.lookup addr tab

    exec : HasIO io =>
           IORef (ConnTab.Table io a) ->
           IORef (PubSub io (ConnTab.Event io a)) ->
           ConnTab.Cmd io a ->
           io ()
    exec tabRef eventsRef (Open addr ctrl) = do
        modifyIORef tabRef (Map.insert addr ctrl)
        pubIORef eventsRef $ ConnTab.Opened addr ctrl
    exec tabRef eventsRef (Send addr msg) = do
        mCtrl <- lookup tabRef addr
        whenJust mCtrl (\ctrl => send ctrl msg)
    exec tabRef eventsRef (Close addr) = do
        modifyIORef tabRef (Map.delete addr)
        mCtrl <- lookup tabRef addr
        whenJust mCtrl close

    export
    new : HasIO io => io (ConnTab.ConnTab io a)
    new = do
        eventsRef <- newIORef emptyPubSub
        tabRef <- newIORef Map.empty
        pure $ MkConnTab
                { device = MkDevice eventsRef (exec tabRef eventsRef)
                , table = tabRef
                }
