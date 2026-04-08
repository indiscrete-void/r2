|||
||| Supports:
||| - freely named addrs e.g. `alice`
||| - hierarchical addrs e.g. `bob/alice`
|||
module Aura.Addr

import Aura.WebSocket
import Data.List1
import JSON.Derive

%language ElabReflection

public export
data NameAddr = MkNameAddr String

export
implementation Show NameAddr where
    show (MkNameAddr str) = str

%runElab derive "NameAddr" [Eq,Ord,ToJSON,FromJSON]

export
Eq NameAddr where
    (MkNameAddr a) == (MkNameAddr b) = a == b

public export
data RoutedAddr addr = MkRoutedAddr addr addr

export
implementation Show addr => Show (RoutedAddr addr) where
    show (MkRoutedAddr from to) = show from ++ "/" ++ show to

%runElab derive "RoutedAddr" [Eq,Ord,ToJSON,FromJSON]

public export
data NetworkAddr
    = MkNetworkNameAddr NameAddr
    | MkNetworkRoutedAddr (RoutedAddr NetworkAddr)

export
covering
implementation Show NetworkAddr where
    show (MkNetworkNameAddr addr) = show addr
    show (MkNetworkRoutedAddr addr) = show addr

%runElab derive "NetworkAddr" [Eq,Ord,ToJSON,FromJSON]

export
listToNetAddr : List1 NameAddr -> NetworkAddr
listToNetAddr (hop ::: rest) = loop (MkNetworkNameAddr hop) rest where
    loop : NetworkAddr -> List NameAddr -> NetworkAddr
    loop acc (hop :: rest) = loop (MkNetworkRoutedAddr $ MkRoutedAddr acc $ MkNetworkNameAddr hop) rest
    loop acc [] = acc

export
netAddrToList : NetworkAddr -> List1 NameAddr
netAddrToList (MkNetworkNameAddr name) = name ::: []
netAddrToList (MkNetworkRoutedAddr (MkRoutedAddr a b)) = netAddrToList a ++ netAddrToList b
