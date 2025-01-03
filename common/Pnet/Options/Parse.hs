module Pnet.Options.Parse (transport, address) where

import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Options.Applicative
import Pnet.Routing
import Pnet
import Transport.Maybe

transport :: ReadM Transport
transport = do
  arg <- str
  pure
    if arg == "-"
      then Stdio
      else Process arg

address :: ReadM Address
address = str >>= maybeFail "invalid node ID" . parseNodeID
  where
    parseNodeID = fmap (Addr . fromInteger . bsToInteger) . decodeBase58 bitcoinAlphabet . BC.pack
