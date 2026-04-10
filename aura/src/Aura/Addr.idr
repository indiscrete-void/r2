|||
||| Supports:
||| - freely named addrs e.g. `alice`
||| - hierarchical addrs e.g. `bob/alice`
|||
||| Show and FromString instances are defined
||| Convenient /> operator is provided
|||
module Aura.Addr

import Aura.WebSocket
import Data.List1
import Language.Reflection
import Derive.Prelude
import JSON

%language ElabReflection

public export
data NameAddr = MkNameAddr String

export
FromString NameAddr where
    fromString = MkNameAddr

export
implementation Show NameAddr where
    show (MkNameAddr str) = str

%runElab derive "NameAddr" [Eq,Ord]

export
Eq NameAddr where
    (MkNameAddr a) == (MkNameAddr b) = a == b

public export
data RoutedAddr addr = MkRoutedAddr addr addr

export
implementation Show addr => Show (RoutedAddr addr) where
    show (MkRoutedAddr from to) = show from ++ "/" ++ show to

%runElab derive "RoutedAddr" [Eq,Ord]

public export
data NetworkAddr
    = MkNetworkNameAddr NameAddr
    | MkNetworkRoutedAddr (RoutedAddr NetworkAddr)

export
FromString NetworkAddr where
    fromString = MkNetworkNameAddr . MkNameAddr

export
covering
implementation Show NetworkAddr where
    show (MkNetworkNameAddr addr) = show addr
    show (MkNetworkRoutedAddr addr) = show addr

export
parseNameAddr : String -> Maybe NameAddr
parseNameAddr str =
    if str == "" then Nothing
    else if '/' `isIn` str then Nothing
    else Just (MkNameAddr str)
    where
    isIn : Char -> String -> Bool
    isIn c s = any (== c) (unpack s)

splitFirst : String -> Maybe (String, String)
splitFirst str =
    let chars = unpack str
    in case span (/= '/') chars of
        (left, '/' :: right) =>
            let leftStr = pack left
                rightStr = pack right
            in if leftStr == "" || rightStr == ""
                then Nothing
                else Just (leftStr, rightStr)
        _ => Nothing

export
parseNetworkAddr : String -> Maybe NetworkAddr
parseNetworkAddr str =
    case splitFirst str of
        Nothing => map MkNetworkNameAddr (parseNameAddr str)
        Just (left, right) => do
            leftAddr <- parseNetworkAddr left
            rightAddr <- parseNetworkAddr right
            Just (MkNetworkRoutedAddr (MkRoutedAddr leftAddr rightAddr))

export
ToJSON NetworkAddr where
    toJSON addr = toJSON (show addr)

export
FromJSON NetworkAddr where
    fromJSON json = do
        str <- fromJSON json
        case parseNetworkAddr str of
            Nothing => Left ([], "Invalid network address format")
            Just addr => Right addr

%runElab derive "NetworkAddr" [Eq,Ord]

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

public export
interface CanRoute l r where
  constructor MkCanRoute
  route : l -> r -> NetworkAddr

public export
CanRoute NetworkAddr NetworkAddr where
    route l r = MkNetworkRoutedAddr (MkRoutedAddr l r)

public export
CanRoute NameAddr NetworkAddr where
    route l r = MkNetworkRoutedAddr (MkRoutedAddr (MkNetworkNameAddr l) r)

public export
CanRoute NetworkAddr NameAddr where
    route l r = MkNetworkRoutedAddr (MkRoutedAddr l (MkNetworkNameAddr r))

public export
CanRoute NameAddr NameAddr where
    route l r = MkNetworkRoutedAddr (MkRoutedAddr (MkNetworkNameAddr l) (MkNetworkNameAddr r))

public export
CanRoute String String where
    route l r = route (MkNameAddr l) (MkNameAddr r)

infixl 5 />

|||
||| Convenient hierarchical addr construction:
||| ```
||| > "a" /> "b"
||| MkNetworkRoutedAddr (MkRoutedAddr (MkNetworkNameAddr (MkNameAddr "a")) (MkNetworkNameAddr (MkNameAddr "b")))
||| ```
|||
public export
(/>) : CanRoute l r => l -> r -> NetworkAddr
(/>) = route
