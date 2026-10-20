{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The anti-drift gate for the metric catalog (D-9).
--
-- Three cheap tests, and the third is the one that earns its keep: it EXECUTES every embedded
-- statement against the real view set. A formula that references a column we renamed, or a view we
-- have not created, fails here rather than at the first request for that number.
module UnitTests.MetricCatalog (tests) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Maybe (isJust)
import Data.Text (Text, pack)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Database.Persist.Sql (rawExecute)
import Palmares.Metrics.Catalog
import Query.Views (applyPalmaresSchema)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "metric catalog"
    [ -- Eight: the seven ids the API publishes plus votes_by_type_v1, which ships as a statement
      -- while the API contract's table omits it even though the DTO carries the field.
      testCase "catalog parses and holds exactly the eight published formula ids" $ do
        fs <- either assertFailure' pure metricCatalog
        map mfFormulaId fs
          @?= [ "participation_rate_v1",
                "rationale_rate_v1",
                "age_days_v1",
                "delegator_retention_rate_v1",
                "vote_latency_median_hours_v1",
                "votes_by_type_v1",
                "gov_action_state_v1",
                "tally_cast_votes_v1"
              ]
        retentionWindowEpochs @?= 10,
      -- Both directions. A referenced-but-missing file would 500 at request time; an
      -- embedded-but-unreferenced file is a formula nobody can discover, which is the same drift
      -- in the other direction.
      -- D-9 made mechanical: the bytes /metrics/formulas publishes are the bytes the query path
      -- executes, read out of the same embed. A hand-maintained `sql` in the JSON would be a
      -- second source to drift.
      testCase "resolvedMetricCatalog inlines the six statements and leaves the two views alone" $
        case resolvedMetricCatalog of
          Left e -> assertFailure e
          Right fs -> do
            length [f | f <- fs, isJust (mfSql f)] @?= 6
            -- a formula with no statement of its own must have no `sql`, not an empty string:
            -- an empty string reads as "we ran nothing", which is false
            [mfFormulaId f | f <- fs, mfSqlFile f == Nothing, mfSql f /= Nothing] @?= []
            forM_ fs $ \f ->
              case (mfSqlFile f, mfSql f) of
                (Just name, Just sql) -> do
                  assertBool
                    (T.unpack (mfFormulaId f) <> "'s inlined sql must be the embedded file verbatim")
                    (sql == decodeUtf8 (maybe "" id (lookupMetricSql (pack name))))
                  assertBool (T.unpack (mfFormulaId f) <> "'s sql must not be empty") (not (T.null sql))
                (Just name, Nothing) -> assertFailure (name <> " did not resolve")
                _ -> pure (),
      testCase "every sql_file resolves to an embedded file, and every embedded file is in the catalog" $ do
        fs <- either assertFailure' pure metricCatalog
        let referenced = [f | Just f <- map mfSqlFile fs]
        sort referenced @?= sort (map fst metricSql)
        mapM_ (\f -> assertBool (f <> " is embedded") (isJust (lookupMetricSql (pack f)))) referenced,
      -- Exactly one of sql_file / sql_object, so every published formula_id resolves to something
      -- a reader can go and look at.
      testCase "each formula names either a statement or a view, never both and never neither" $ do
        fs <- either assertFailure' pure metricCatalog
        forM_ fs $ \f ->
          assertBool
            (show (mfFormulaId f) <> " must name exactly one of sql_file / sql_object")
            (isJust (mfSqlFile f) /= isJust (mfSqlObject f)),
      -- postgresql-simple counts placeholders LEXICALLY over the whole statement, comments
      -- included, so a question mark in prose is read as a parameter. That already happened once
      -- here and surfaced as an opaque FormatError at execution; asserting the count makes it a
      -- named failure instead.
      testCase "each statement has exactly as many placeholders as it declares parameters" $ do
        fs <- either assertFailure' pure metricCatalog
        forM_ [(f, s) | f <- fs, Just n <- [mfSqlFile f], Just s <- [lookupMetricSql (pack n)]] $ \(f, s) ->
          assertEqual
            (show (mfFormulaId f) <> ": placeholder count must equal the params array")
            (length (mfParams f))
            (T.count "?" (decodeUtf8 s)),
      -- PREPARE, which parses the statement and resolves every table, column, function and cast
      -- against the real view set WITHOUT running it.
      --
      -- Executing was the first attempt and does not work: persistent's `rawExecute` rejects a
      -- statement that returns columns ("execute resulted in Col 4-column result"), and these are
      -- all SELECTs. `rawSql` is no good either, because it needs a result type per statement and
      -- the six shapes differ. PREPARE returns no rows, so it fits `rawExecute`, and it is also
      -- the cheaper check: no scan over three million rows to find out a column name is wrong.
      --
      -- PostgreSQL's PREPARE only accepts $n, so the client-side `?` placeholders are translated
      -- here. That translation is test-only: Query.Metrics will hand the files to persistent,
      -- which interpolates `?` itself.
      testCase "every embedded statement parses and resolves against the real view set" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          fs <- either assertFailure' pure metricCatalog
          forM_ [(f, s) | f <- fs, Just n <- [mfSqlFile f], Just s <- [lookupMetricSql (pack n)]] $ \(f, s) ->
            runPg pool $
              rawExecute
                ("PREPARE " <> mfFormulaId f <> " AS " <> toDollarPlaceholders (dropTrailingSemicolon (decodeUtf8 s)))
                []
    ]
  where
    assertFailure' e = assertFailure ("metric catalog did not parse: " <> e)

-- | Rewrite client-side `?` placeholders as PostgreSQL's positional $n, in order.
--
-- Safe here because UnitTests.MetricCatalog also asserts that a question mark appears in these
-- files exactly as many times as the formula declares parameters — so there is no `?` in a string
-- literal or a comment for this to mangle.
toDollarPlaceholders :: Text -> Text
toDollarPlaceholders = go (1 :: Int)
  where
    go n t = case T.breakOn "?" t of
      (before, rest)
        | T.null rest -> before
        | otherwise -> before <> "$" <> T.pack (show n) <> go (n + 1) (T.drop 1 rest)

-- | PREPARE takes one statement and no trailing semicolon.
dropTrailingSemicolon :: Text -> Text
dropTrailingSemicolon = T.dropWhileEnd (`elem` (";\n\r\t " :: String))

