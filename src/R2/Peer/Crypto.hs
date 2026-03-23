module R2.Peer.Crypto where

import Crypto.Noise.DH
import Data.ByteArray
import Data.ByteString (ByteString)
import Data.ByteString.Base58
import Data.ByteString.Char8 qualified as BC
import Polysemy
import R2.Peer.FilePaths
import Text.Printf

data GenKey m a where
  GenKey :: (DH d) => GenKey m (KeyPair d)

makeSem ''GenKey

genKeyToIO :: (Member (Embed IO) r) => InterpreterFor GenKey r
genKeyToIO = interpret \case GenKey -> embed dhGenKey

scrubbedBytesToBase58String :: ScrubbedBytes -> String
scrubbedBytesToBase58String = BC.unpack . encodeBase58 flickrAlphabet . convert @_ @ByteString

showPublicKey :: (DH d) => PublicKey d -> String
showPublicKey = scrubbedBytesToBase58String . dhPubToBytes

unsafeShowSecretKey :: (DH d) => SecretKey d -> String
unsafeShowSecretKey = scrubbedBytesToBase58String . dhSecToBytes

data KeyStore m a where
  StoreKeyPair :: (DH d) => KeyPair d -> KeyStore m FilePath

makeSem ''KeyStore

keyStoreToIO :: (Member (Embed IO) r) => InterpreterFor KeyStore r
keyStoreToIO = interpret \case
  StoreKeyPair (secret, public) -> do
    let secretString = unsafeShowSecretKey secret
    let publicString = showPublicKey public
    kpPath <- embed $ getUsableKeyPairDir publicString
    let secretPath :: String = printf "%s/secret" kpPath
    embed $ writeFile secretPath secretString
    pure secretPath
