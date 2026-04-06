module Addr

import WebSocket
import Data.List1
import JSON.Derive

%language ElabReflection

public export
data NameAddr = MkNameAddr String

%runElab derive "NameAddr" [Show,Eq,ToJSON,FromJSON]

export
Eq NameAddr where
    (MkNameAddr a) == (MkNameAddr b) = a == b

public export
data RoutedAddr addr = MkRoutedAddr addr addr

%runElab derive "RoutedAddr" [Show,Eq,ToJSON,FromJSON]

public export
data NetworkAddr
    = MkNetworkNameAddr NameAddr
    | MkNetworkRoutedAddr (RoutedAddr NetworkAddr)

%runElab derive "NetworkAddr" [Show,Eq,ToJSON,FromJSON]

export
netAddrToList : NetworkAddr -> List1 NameAddr
netAddrToList (MkNetworkNameAddr name) = name ::: []
netAddrToList (MkNetworkRoutedAddr (MkRoutedAddr a b)) = netAddrToList a ++ netAddrToList b
