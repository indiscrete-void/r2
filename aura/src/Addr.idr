module Addr

import WebSocket
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
    show (MkRoutedAddr a b) = show a ++ "/" ++ show b

%runElab derive "RoutedAddr" [Eq,ToJSON,FromJSON]

public export
data NetworkAddr
    = MkNetworkNameAddr NameAddr
    | MkNetworkRoutedAddr (RoutedAddr NetworkAddr)

export
covering
implementation Show NetworkAddr where
    show (MkNetworkNameAddr addr) = show addr
    show (MkNetworkRoutedAddr addr) = show addr

%runElab derive "NetworkAddr" [Eq,ToJSON,FromJSON]

export
netAddrToList : NetworkAddr -> List1 NameAddr
netAddrToList (MkNetworkNameAddr name) = name ::: []
netAddrToList (MkNetworkRoutedAddr (MkRoutedAddr a b)) = netAddrToList a ++ netAddrToList b
