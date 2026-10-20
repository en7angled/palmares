-- | Stub suite. The real tree (PropertyTests, TestRuns, UnitTests.*) arrives with the extraction
-- block; this stub exists so `cabal test all` is a green gate from the first build.
module Main (main) where

import System.Exit (exitSuccess)

main :: IO ()
main = exitSuccess
