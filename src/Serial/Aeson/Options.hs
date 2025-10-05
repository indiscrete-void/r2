module Serial.Aeson.Options (aesonOptions, aesonRemovePrefix) where

import Data.Aeson (Options (..), SumEncoding (..), defaultOptions)
import Data.Char (toLower)
import Data.List qualified as List
import Data.Maybe qualified as Maybe

aesonOptions :: Options
aesonOptions =
  defaultOptions
    { sumEncoding = ObjectWithSingleField
    }

stripPrefixOrSkip :: (Eq a) => [a] -> [a] -> [a]
stripPrefixOrSkip prefix fieldName = Maybe.fromMaybe fieldName (List.stripPrefix prefix fieldName)

lowerFirst :: [Char] -> [Char]
lowerFirst (x : xs) = toLower x : xs
lowerFirst "" = ""

aesonRemovePrefix :: String -> Options
aesonRemovePrefix prefix =
  aesonOptions
    { fieldLabelModifier = lowerFirst . stripPrefixOrSkip prefix
    }
