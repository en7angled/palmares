{-# LANGUAGE OverloadedStrings #-}

-- | Running a published formula, by @formula_id@, from the catalog's own embedded bytes.
--
-- Two test modules need this and neither may carry a copy of a formula: 'UnitTests.MetricFixture'
-- compares the catalog against a synced preprod database, and 'UnitTests.MetricAgreement' compares
-- it against what @query-api@ serves from the matview. A helper that re-typed the SQL would make
-- both of them tests of themselves.
module Test.Metrics
  ( runMetric,
    lookupFormula,
  )
where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.Persist (PersistValue)
import Database.Persist.Sql (ConnectionPool, RawSql, rawSql)
import Palmares.Metrics.Catalog
import Test.Pg (runPg)

-- | Look the statement up by @formula_id@ and bind the catalog's parameters in order.
--
-- The parameter-count check is not decoration: the placeholders are positional, so a catalog entry
-- whose @params@ array has drifted from its @.sql@ file would bind the wrong value to the right
-- hole and still return a number.
runMetric :: (RawSql r) => ConnectionPool -> Text -> [PersistValue] -> IO [r]
runMetric pool fid params = do
  formulas <- either (fail . ("metric catalog did not parse: " <>)) pure metricCatalog
  f <- maybe (fail ("no catalog entry " <> T.unpack fid)) pure (lookupFormula fid formulas)
  name <- maybe (fail (T.unpack fid <> " has no sql_file")) pure (mfSqlFile f)
  sql <- maybe (fail (name <> " is not embedded")) pure (lookupMetricSql (T.pack name))
  unless (length params == length (mfParams f)) $
    fail (T.unpack fid <> ": the catalog declares " <> show (length (mfParams f)) <> " parameters")
  runPg pool (rawSql (TE.decodeUtf8 sql) params)

-- | The catalog entry with this @formula_id@.
lookupFormula :: Text -> [MetricFormula] -> Maybe MetricFormula
lookupFormula fid = foldr (\f acc -> if mfFormulaId f == fid then Just f else acc) Nothing
