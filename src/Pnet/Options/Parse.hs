module Pnet.Options.Parse (transport, address) where

import Options.Applicative
import Pnet
import Pnet.Routing
import Transport.Maybe

transport :: ReadM Transport
transport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = str >>= maybeFail "invalid node ID" . parseAddressBase58
