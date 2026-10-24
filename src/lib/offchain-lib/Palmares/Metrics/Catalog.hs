{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The metric catalog: what each published number means, and the SQL that defines it.
--
-- The catalog is the single source of truth. For @delegator_retention_rate_v1@ that is literally
-- the executed statement: 'Query.Gov.delegatorStatsQuery' runs these bytes. For the five DRep
-- metrics it is a definition the server implements elsewhere — @palmares.drep_metrics@ computes
-- them batched over every DRep, because a per-DRep statement run ~800 times pays a 3.2 M-row vote
-- pass each time (@sql\/030_metrics.sql@'s header has the measurement).
--
-- __So the agreement is asserted, not assumed.__ There was a promise here that it could not
-- disagree, and it did: the matview's @eligible_actions@ counted vote ROWS, which inflated the
-- denominator of every DRep that re-voted on a settled action (@GV-03@). The gates that exist now
-- are @UnitTests.MetricAgreement@, which compares the served response against every formula below
-- for every DRep in a seeded corpus, and @sql\/checks\/070_drep_metrics.sql@, which repeats it
-- against a synced preprod database.
--
-- Two mechanical rules keep it honest, both learned the hard way in this codebase:
--
--   * 'makeRelativeToProject' is mandatory. A bare 'embedFile' resolves against the compile-time
--     working directory, which differs in the Docker build.
--   * one 'embedFile' per file, never @embedDir@. @embedDir@ registers a dependency on the files
--     it FOUND, so adding a new @.sql@ would not invalidate this module and CI could pass against
--     a stale embed — which defeats the point.
--
-- Every path embedded here must also appear in @extra-source-files@, or @cabal sdist@ and the
-- image build omit it.
module Palmares.Metrics.Catalog
  ( MetricFormula (..),
    catalogJson,
    metricSql,
    metricCatalog,
    resolvedMetricCatalog,
    lookupMetricSql,
    retentionWindowEpochs,
  )
where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.Swagger (ToSchema (..), genericDeclareNamedSchema)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Deriving.Aeson
import Palmares.Utils (mkStripPrefixSchemaOptions)

-- | One catalog entry.
--
-- The field prefix is @mf@ and not @formula@: stripping @formula@ would emit @id@ where the wire
-- format says @formula_id@.
data MetricFormula = MetricFormula
  { mfFormulaId :: Text,
    mfName :: Text,
    -- | The response field this formula produces.
    mfField :: Text,
    mfExpression :: Text,
    -- | What the denominator counts, in words. 'Nothing' for formulas that are not ratios.
    mfDenominator :: Maybe Text,
    -- | The condition under which the value is @null@ rather than zero. Publishing this is the
    -- difference between "no data" and "zero", which for a person's track record is not a
    -- cosmetic distinction.
    mfNullWhen :: Maybe Text,
    mfInputs :: [Text],
    mfEdgeCases :: [Text],
    -- | The embedded statement that computes it, or 'Nothing' for a formula that is a view.
    mfSqlFile :: Maybe FilePath,
    -- | The view that embodies it, for the formulas with no statement of their own. Exactly one
    -- of 'mfSqlFile' and 'mfSqlObject' is set, so every published @formula_id@ resolves to
    -- something a reader can go and look at.
    mfSqlObject :: Maybe Text,
    -- | Positional parameter names, in the order the statement's @?@ placeholders bind them.
    mfParams :: [Text],
    mfSpec :: Text,
    mfVersion :: Int,
    -- | The statement itself, inlined.
    --
    -- Absent from @resources\/metric-formulas.json@ and filled by 'resolvedMetricCatalog', which
    -- is what makes D-9 true rather than promised: the bytes the endpoint publishes are the bytes
    -- the server executes, read out of the same embed. A hand-maintained copy in the JSON would
    -- be a second source to drift.
    mfSql :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "mf", CamelToSnake]] MetricFormula

instance ToSchema MetricFormula where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "mf")

-- | The catalog, as published by @GET \/metrics\/formulas@ and the MCP resource.
catalogJson :: ByteString
catalogJson = $(makeRelativeToProject "resources/metric-formulas.json" >>= embedFile)

-- | The statements, one 'embedFile' each.
metricSql :: [(FilePath, ByteString)]
metricSql =
  [ ("age_days_v1.sql", $(makeRelativeToProject "resources/metrics/age_days_v1.sql" >>= embedFile)),
    ( "delegator_retention_rate_v1.sql",
      $(makeRelativeToProject "resources/metrics/delegator_retention_rate_v1.sql" >>= embedFile)
    ),
    ( "participation_rate_v1.sql",
      $(makeRelativeToProject "resources/metrics/participation_rate_v1.sql" >>= embedFile)
    ),
    ("rationale_rate_v1.sql", $(makeRelativeToProject "resources/metrics/rationale_rate_v1.sql" >>= embedFile)),
    ( "vote_latency_median_hours_v1.sql",
      $(makeRelativeToProject "resources/metrics/vote_latency_median_hours_v1.sql" >>= embedFile)
    ),
    ("votes_by_type_v1.sql", $(makeRelativeToProject "resources/metrics/votes_by_type_v1.sql" >>= embedFile))
  ]

-- | The parsed catalog, or the parse error. Not a partial function: a malformed catalog is a
-- startup failure for the caller to report, not an exception from a pure value.
metricCatalog :: Either String [MetricFormula]
metricCatalog = eitherDecodeStrict' catalogJson

-- | The catalog with every @sql_file@ resolved to its embedded bytes.
--
-- A @sql_file@ naming a file that is not embedded is a @Left@, not a silently empty @sql@ field:
-- it means the catalog and the embed list disagree, which would publish a formula nobody can
-- read. The caller reports it at startup.
resolvedMetricCatalog :: Either String [MetricFormula]
resolvedMetricCatalog = metricCatalog >>= traverse resolve
  where
    resolve f = case mfSqlFile f of
      Nothing -> Right f
      Just name -> case lookupMetricSql (T.pack name) of
        Just bytes -> Right f {mfSql = Just (TE.decodeUtf8 bytes)}
        Nothing ->
          Left
            ( "Palmares.Metrics.Catalog: " <> T.unpack (mfFormulaId f) <> " names sql_file "
                <> show name
                <> ", which is not in metricSql. Add an embedFile line, and the path to extra-source-files."
            )

-- | The statement behind a @sql_file@ name.
lookupMetricSql :: Text -> Maybe ByteString
lookupMetricSql name = lookup (T.unpack name) metricSql

-- | The retention window, in epochs.
--
-- ONE constant, bound into @delegator_retention_rate_v1.sql@ as a parameter. Writing 10 in the
-- SQL and 10 in the code is how the published formula and the served number drift apart.
retentionWindowEpochs :: Int
retentionWindowEpochs = 10
