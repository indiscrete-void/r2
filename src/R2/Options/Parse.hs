module R2.Options.Parse (transport, address) where

import Options.Applicative
import R2
import R2.Routing
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
