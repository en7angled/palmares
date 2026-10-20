{-# LANGUAGE OverloadedStrings #-}

-- | The drift gate for @docs/metrics.md@.
--
-- The committed file must be exactly what the catalog renders. CI also runs the generator and
-- diffs, which catches the same drift from the other side; this test catches it without needing
-- a working tree, so a developer sees it before pushing.
module UnitTests.MetricDoc (tests) where

import Control.Monad (forM_)
import Data.Text (pack)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Text.IO qualified as T
import Palmares.Metrics.Catalog
import Palmares.Metrics.Doc (renderMetricsDoc)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "metrics doc"
    [ testCase "the committed docs/metrics.md is exactly what the catalog renders" $ do
        fs <- either assertFailure' pure metricCatalog
        committed <- T.readFile "docs/metrics.md"
        renderMetricsDoc fs @?= committed,
      -- Inlined, not linked: a link can point at a file that has since changed, while the fenced
      -- block plus this assertion means the page always shows the statement actually in force.
      testCase "every formula's SQL is inlined in the doc, so prose cannot drift from code" $ do
        fs <- either assertFailure' pure metricCatalog
        let doc = renderMetricsDoc fs
        forM_ [(f, s) | f <- fs, Just n <- [mfSqlFile f], Just s <- [lookupMetricSql (pack n)]] $ \(f, s) ->
          assertBool
            (show (mfFormulaId f) <> ": its SQL must appear verbatim in the doc")
            (T.stripEnd (decodeUtf8 s) `T.isInfixOf` doc),
      -- A view-backed formula has no statement to inline, so the doc must still say where to look
      -- or the entry is undiscoverable.
      testCase "a view-backed formula names its view in the doc" $ do
        fs <- either assertFailure' pure metricCatalog
        let doc = renderMetricsDoc fs
        forM_ [o | f <- fs, Just o <- [mfSqlObject f]] $ \o ->
          assertBool (show o <> " must appear in the doc") (o `T.isInfixOf` doc)
    ]
  where
    assertFailure' e = assertFailure ("metric catalog did not parse: " <> e)
