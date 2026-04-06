module PubSub

import Data.IORef

public export
record PubSub (m : Type -> Type) (a : Type) where
    constructor MkPubSub
    listeners : List (a -> m ())

export
emptyPubSub : PubSub m a
emptyPubSub = MkPubSub []

export
sub : PubSub m a -> (a -> m ()) -> PubSub m a
sub site listener = MkPubSub (listener :: listeners site)

export
pub : Applicative m => PubSub m a -> (a -> m ())
pub site a = traverse_ ($ a) (listeners site)

export
subIORef : HasIO io => IORef (PubSub io a) -> (a -> io ()) -> io ()
subIORef eventsRef f = modifyIORef eventsRef (`sub` f)

export
pubIORef : HasIO io => IORef (PubSub io a) -> (a -> io ())
pubIORef eventsRef a = do
    events <- readIORef eventsRef
    pub events a
