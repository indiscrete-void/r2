module Aura.URL

import Aura.Addr
import Data.String
import Data.List1

%default total

public export
record URL where
  constructor MkURL
  scheme : String
  host   : String
  port   : Maybe Int
  path   : List String

export
covering
Show URL where
    show (MkURL scheme host port path) =
        let portPart = case port of Nothing => ""; Just p => ":" ++ show p
            pathPart = if null path then "" else "/" ++ joinBy "/" path
         in "\{scheme}://\{host}" ++ portPart ++ pathPart

splitFirstChar : Char -> String -> Maybe (String, String)
splitFirstChar c str =
  let (before, after) = break (== c) str in
  case after of
    "" => Nothing
    _  => case unpack after of
            (_ :: rest) => Just (before, pack rest)
            [] => Nothing

parsePort : String -> Maybe Int
parsePort s = if all isDigit (unpack s) then Just (cast s) else Nothing

export
parseURL : String -> Maybe URL
parseURL str = do
  (scheme, rest1) <- splitFirstChar ':' str
  (_, rest2)      <- splitFirstChar '/' rest1
  (_, rest3)      <- splitFirstChar '/' rest2
  let (hostPort, pathRest) = span (/= '/') rest3
  let (host, portMaybe) = case splitFirstChar ':' hostPort of
        Nothing => (hostPort, Nothing)
        Just (h, p) => (h, parsePort p)
  let pathSegments = if pathRest == "" then [] else forget (split (== '/') pathRest)
  pure $ MkURL scheme host portMaybe (filter (/= "") pathSegments)

export
urlToNetworkAddr : URL -> NetworkAddr
urlToNetworkAddr (MkURL scheme host port paths) =
  let base = MkNameAddr scheme /> MkNameAddr host
      withPort = maybe base (\p => base /> MkNameAddr (show p)) port
  in foldl (\acc, seg => acc /> MkNameAddr seg) withPort paths

export
parseURLToNetworkAddr : String -> Maybe NetworkAddr
parseURLToNetworkAddr s = map urlToNetworkAddr (parseURL s)
