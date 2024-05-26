module Polysemy.Socket.Accept
  ( Accept,
    accept,
    handleClient,
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

handleClient :: (Member (Accept s) r, Member Async r) => (s -> Sem r a) -> Sem r a
handleClient f = forever $ accept >>= async . f

acceptToIO :: (Member (Embed IO) r) => IO.Socket -> InterpreterFor (Accept IO.Socket) r
acceptToIO server = interpret \case
  Accept -> embed $ fst <$> IO.accept server
