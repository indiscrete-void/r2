module R2.Log where

import Control.Exception
import Polysemy
import System.IO
import Text.Printf

traceIOExceptions :: Sem (Embed IO ': r) a -> Sem (Embed IO ': r) a
traceIOExceptions m = embed (hSetBuffering stderr LineBuffering) >> reinterpret go m
  where
    go (Embed io) = embed do
      result <- try @IOException io
      case result of
        Left err -> hPutStrLn stderr (printf "error: %s" (show err)) >> throw err
        Right a -> pure a
