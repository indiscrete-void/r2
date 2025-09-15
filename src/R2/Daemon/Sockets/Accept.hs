module R2.Daemon.Sockets.Accept
  ( Accept,
    accept,
    foreverAcceptAsync,
    acceptToIO,
  )
where

import Control.Monad
import Network.Socket qualified as IO
import Polysemy hiding (send)
import Polysemy.Async

data Accept s m a where
  Accept :: Accept s m s

makeSem ''Accept

foreverAcceptAsync :: (Member (Accept s) r, Member Async r) => (s -> Sem r a) -> Sem r a
foreverAcceptAsync f = forever $ accept >>= async . f

acceptToIO :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor (Accept IO.Socket) r
acceptToIO server = interpret \case
  Accept -> embed $ fst <$> IO.accept server
