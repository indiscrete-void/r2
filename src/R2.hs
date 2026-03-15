module R2
  ( LabelAddr (..),
    TagAddr (..),
    RoutedAddr (..),
    NameAddr (..),
    NetworkAddr (..),
    AddrSet (..),
    NetworkAddrSet,
    RouteTo (..),
    RoutedFrom (..),
    RouteToErr (..),
    r2,
    (/>),
    parseTagAddr,
    parseRoutedAddr,
    parseNameAddr,
    parseNetAddr,
    netAddrHead,
    emptyAddrSet,
    bestAddrSetRepresentative,
    singleAddrSet,
    addrSetsReferToSameNode,
    routedAddrSet,
    netAddrEnd,
    bestAddrSetName,
    netAddrToList,
    mapAddrSet,
    addrSetUnions,
    addrSetFromList,
  )
where

import Control.Applicative
import Data.Aeson
import Data.Aeson qualified as Aeson
import Data.Aeson.TH
import Data.ByteString.Base58
import Data.ByteString.Base58.Internal
import Data.ByteString.Char8 qualified as BC
import Data.DoubleWord
import Data.List.Extra
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.String (IsString (..))
import Data.Text qualified as Text
import Data.Word
import GHC.Generics
import Serial.Aeson.Options
import System.Random.Stateful
import Text.Printf (printf)

newtype LabelAddr = LabelAddr {labelAddr :: String}
  deriving stock (Ord, Eq, Generic)

instance Show LabelAddr where
  show (LabelAddr name) = name

instance IsString LabelAddr where
  fromString = LabelAddr

breakAround :: (Eq a) => [a] -> [a] -> ([a], [a])
breakAround delim list =
  let (start, match) = breakOn delim list
   in if null match
        then (list, [])
        else
          let end = tail match
           in if null end
                then (list, [])
                else (start, end)

data TagAddr = TagAddr {taggedAddrKey :: String, taggedAddrValue :: String}
  deriving stock (Ord, Eq, Generic)

instance Show TagAddr where
  show TagAddr {..} = printf "%s:%s" taggedAddrKey taggedAddrValue

parseTagAddr :: String -> Maybe TagAddr
parseTagAddr strAddr =
  let (tag, value) = breakAround ":" strAddr
   in if null value
        then Nothing
        else Just $ TagAddr tag value

data RoutedAddr a b = RoutedAddr {routedAddrRouter :: a, routedAddrDestination :: b}
  deriving stock (Ord, Eq, Generic)

instance (Show a, Show b) => Show (RoutedAddr a b) where
  show RoutedAddr {..} = printf "%s/%s" (show routedAddrRouter) (show routedAddrDestination)

parseRoutedAddr :: (String -> Maybe a) -> (String -> Maybe b) -> String -> Maybe (RoutedAddr a b)
parseRoutedAddr routerIso destinationIso strAddr =
  let (router, destination) = breakAround "/" strAddr
   in if null destination
        then Nothing
        else RoutedAddr <$> routerIso router <*> destinationIso destination

data NameAddr
  = NameLabelAddr LabelAddr
  | NameTagAddr TagAddr
  deriving stock (Ord, Eq, Generic)

instance Show NameAddr where
  show (NameLabelAddr addr) = show addr
  show (NameTagAddr addr) = show addr

instance IsString NameAddr where
  fromString = NameLabelAddr . fromString

instance ToJSON NameAddr where
  toJSON addr = Aeson.String (Text.pack $ show addr)

instance FromJSON NameAddr where
  parseJSON = Aeson.withText "NameAddr" (maybe (fail "cannot decode name addr") pure . parseNameAddr . Text.unpack)

parseNameAddr :: String -> Maybe NameAddr
parseNameAddr str =
  (NameTagAddr <$> parseTagAddr str)
    <|> Just (NameLabelAddr $ fromString str)

data NetworkAddr
  = NetworkNameAddr NameAddr
  | NetworkRoutedAddr (RoutedAddr NetworkAddr NetworkAddr)
  deriving stock (Ord, Eq, Generic)

netAddrHead :: NetworkAddr -> NameAddr
netAddrHead (NetworkNameAddr local) = local
netAddrHead (NetworkRoutedAddr (RoutedAddr a _)) = netAddrHead a

netAddrEnd :: NetworkAddr -> NameAddr
netAddrEnd (NetworkNameAddr local) = local
netAddrEnd (NetworkRoutedAddr (RoutedAddr _ b)) = netAddrEnd b

instance Show NetworkAddr where
  show (NetworkNameAddr addr) = show addr
  show (NetworkRoutedAddr addr) = show addr

instance IsString NetworkAddr where
  fromString = NetworkNameAddr . fromString

parseNetAddr :: String -> Maybe NetworkAddr
parseNetAddr str =
  NetworkRoutedAddr <$> parseRoutedAddr parseNetAddr parseNetAddr str
    <|> NetworkNameAddr <$> parseNameAddr str

instance ToJSON NetworkAddr where
  toJSON addr = Aeson.String (Text.pack $ show addr)

instance FromJSON NetworkAddr where
  parseJSON = Aeson.withText "NetworkAddr" (maybe (fail "cannot decode network addr") pure . parseNetAddr . Text.unpack)

infixr 9 />

(/>) :: NetworkAddr -> NetworkAddr -> NetworkAddr
addr1 /> addr2 = NetworkRoutedAddr $ RoutedAddr addr1 addr2

netAddrToList :: NetworkAddr -> NonEmpty NameAddr
netAddrToList (NetworkNameAddr name) = NonEmpty.singleton name
netAddrToList (NetworkRoutedAddr (RoutedAddr a b)) = netAddrToList a <> netAddrToList b

newtype AddrSet addr = AddrSet {unAddrSet :: Set addr}
  deriving stock (Ord, Eq, Generic)
  deriving (Foldable) via Set

type NetworkAddrSet = AddrSet NetworkAddr

instance (Ord addr) => Semigroup (AddrSet addr) where
  (AddrSet a) <> (AddrSet b) = AddrSet (a <> b)

mapAddrSet :: (Ord b) => (a -> b) -> AddrSet a -> AddrSet b
mapAddrSet f = AddrSet . Set.map f . unAddrSet

addrSetFromList :: (Ord addr) => [addr] -> AddrSet addr
addrSetFromList = AddrSet . Set.fromList

instance (Show addr) => Show (AddrSet addr) where
  show (AddrSet set) = printf "(%s)" $ unwords $ map show $ Set.toList set

addrSetOptions :: Options
addrSetOptions = aesonRemovePrefix "un"

instance (FromJSON addr, Ord addr) => FromJSON (AddrSet addr) where
  parseJSON = genericParseJSON addrSetOptions

instance (ToJSON addr) => ToJSON (AddrSet addr) where
  toJSON = genericToJSON addrSetOptions
  toEncoding = genericToEncoding addrSetOptions

emptyAddrSet :: AddrSet addr
emptyAddrSet = AddrSet Set.empty

singleAddrSet :: addr -> AddrSet addr
singleAddrSet = AddrSet . Set.singleton

bestAddrSetRepresentative :: AddrSet addr -> Maybe addr
bestAddrSetRepresentative = Set.lookupMin . unAddrSet

bestAddrSetName :: NetworkAddrSet -> Maybe NameAddr
bestAddrSetName = fmap netAddrEnd . bestAddrSetRepresentative

addrSetsReferToSameNode :: (Ord addr) => AddrSet addr -> AddrSet addr -> Bool
addrSetsReferToSameNode (AddrSet a) (AddrSet b) = not $ Set.null $ Set.intersection a b

routedAddrSet :: NameAddr -> NetworkAddrSet -> NetworkAddrSet
routedAddrSet addr (AddrSet set) = AddrSet $ Set.map (/> NetworkNameAddr addr) set

addrSetUnions :: (Ord addr) => AddrSet (AddrSet addr) -> AddrSet addr
addrSetUnions = AddrSet . Set.unions . unAddrSet . mapAddrSet unAddrSet

instance Uniform LabelAddr where
  uniformM g = LabelAddr . BC.unpack . encodeBase58 bitcoinAlphabet . integerToBS . toInteger <$> uniformM @Word256 g

instance Uniform Word128 where
  uniformM g = do
    l <- uniformM @Word64 g
    r <- uniformM @Word64 g
    pure $ Word128 l r

instance Uniform Word256 where
  uniformM g = do
    l <- uniformM @Word128 g
    r <- uniformM @Word128 g
    pure $ Word256 l r

data RouteTo msg = RouteTo
  { routeToNode :: NameAddr,
    routeToData :: msg
  }
  deriving stock (Show, Eq, Generic)

$(deriveJSON (aesonRemovePrefix "routeTo") ''RouteTo)

data RoutedFrom msg = RoutedFrom
  { routedFromNode :: NameAddr,
    routedFromData :: msg
  }
  deriving stock (Show, Eq, Generic)

$(deriveJSON (aesonRemovePrefix "routedFrom") ''RoutedFrom)

data RouteToErr = RouteToErr
  { routeToErrNode :: NameAddr,
    routeToErrMessage :: String
  }
  deriving stock (Eq, Show, Generic)

$(deriveJSON (aesonRemovePrefix "routeToErr") ''RouteToErr)

r2 :: (NameAddr -> RoutedFrom msg -> a) -> (NameAddr -> RouteTo msg -> a)
r2 f node (RouteTo receiver maybeStr) = f receiver $ RoutedFrom node maybeStr
