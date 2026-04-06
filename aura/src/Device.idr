module Device

import PubSub
import Data.IORef

public export
record Device (m : Type -> Type) (event : Type) (cmd : Type) where
    constructor MkDevice
    events : IORef (PubSub m event)
    exec : cmd -> m ()

namespace Device
    export
    new : HasIO io => PubSub io event -> (cmd -> io ()) -> io (Device io event cmd)
    new events exec = do
        eventsRef <- newIORef events
        pure $ MkDevice eventsRef exec

    export
    sub : HasIO io => Device io event cmd -> (event -> io ()) -> io ()
    sub (MkDevice eventsRef _) f = subIORef eventsRef f
