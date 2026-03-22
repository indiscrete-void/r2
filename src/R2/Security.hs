-- designed to be imported qualified
module R2.Security where

import Control.Monad
import Polysemy
import Polysemy.Fail
import R2
import Text.Printf

checkPeerIdentityMatch ::
  (Member Fail r) =>
  AddrSet NameAddr ->
  AddrSet NameAddr ->
  Sem r ()
checkPeerIdentityMatch addrSet knownAddrs = do
  unless (null knownAddrs) $
    unless (addrSetsReferToSameNode knownAddrs addrSet) $
      fail (printf "address mismatch")
