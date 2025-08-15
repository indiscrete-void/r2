module Serial.Aeson.Options (aesonOptions) where

import Data.Aeson (Options (..), SumEncoding (..), defaultOptions)
import Data.Char (toLower)
import Data.List qualified as List
import Data.Maybe qualified as Maybe

aesonOptions :: Maybe String -> Options
aesonOptions prefix =
  defaultOptions
    { fieldLabelModifier = case prefix of
        Just prefix -> lowerFirst . stripPrefixOrSkip prefix
        Nothing -> id,
      sumEncoding = ObjectWithSingleField
    }

stripPrefixOrSkip :: (Eq a) => [a] -> [a] -> [a]
stripPrefixOrSkip prefix fieldName = Maybe.fromMaybe fieldName (List.stripPrefix prefix fieldName)

lowerFirst :: [Char] -> [Char]
lowerFirst (x : xs) = toLower x : xs
lowerFirst "" = ""
