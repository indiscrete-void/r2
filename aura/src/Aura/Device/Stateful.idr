module Aura.Device.Stateful

import Aura.Addr

public export
data Event : Type -> Type -> Type where
    Opened : handle -> Event handle a
    Recv : handle -> a -> Event handle a
    Closed : handle -> Event handle a

public export
interface Monad m => Device m a h dev | dev where
    sub : dev -> (Event h a -> m ()) -> m ()
    send : dev -> h -> a -> m ()
    handleToAddr : dev -> h -> NetworkAddr
