module R2.Peer.Polysemy
  ( r2Sem,
    runR2,
    runR2Input,
    runR2Output,
    runR2Close,
    connectR2,
    acceptR2,
    Stream (..),
    ioToR2,
  )
where

import Control.Constraint
import Data.Functor
import Polysemy
import Polysemy.Any
import Polysemy.Async
import Polysemy.Extra.Async
import Polysemy.Extra.Trace
import Polysemy.Fail
import Polysemy.Trace
import Polysemy.Transport
import R2
import R2.Peer
import Text.Printf qualified as Text
