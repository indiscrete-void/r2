module R2.Options (Verbosity, verbosity) where

import Options.Applicative

type Verbosity = Int

verbosity :: Parser Int
verbosity = length <$> many (flag' () (short 'v'))
