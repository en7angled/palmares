{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Which schema attest-sync's projection tables live in.
--
-- __The failure this exists for.__ Every entity in @Palmares.Storage@'s @persistLowerCase@ block is
-- declared unqualified, so @migrateAll@'s @CREATE TABLE@ lands wherever the connection's
-- @search_path@ resolves first. Nothing in the service used to set that path, and
-- @sql/050_roles.sql@ gives @palmares_owner@ @search_path = palmares, palmares_attest, public@ — so
-- the tables landed in @palmares@, the schema @sql/000_schema.sql@ __drops CASCADE on every
-- query-api boot__. One restart of the read API would have deleted the chain-sync state and cost a
-- full Kupo re-sync, with no error anywhere.
--
-- So the assertion is not "the tables exist" but __"the tables survive the drop"__, which is the
-- thing that was actually broken.
module UnitTests.AttestSchema (tests) where

import Data.List (sort)
import Data.Text qualified as T
import Database.Persist.Sql (ConnectionPool, Single (..), rawExecute, rawSql, toPersistValue)
import Palmares.Storage (attestSchema, chainSyncTableNames, currentSchemaVersion, ensureAttestSchema, runAttest, runMigrations)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "attest-sync schema ownership"
    [ testCase "the projections are created in palmares_attest, not in palmares and not in public" $
        withScratchDb $ \pool -> do
          -- The adversarial setup: `palmares` exists AND comes first on the search_path, exactly as
          -- `sql/050_roles.sql` leaves it for `palmares_owner`. Without the pin, this is the
          -- configuration in which the tables go to the wrong place.
          runPg pool $ do
            rawExecute "CREATE SCHEMA IF NOT EXISTS palmares" []
            rawExecute "SET search_path TO palmares, palmares_attest, public" []
          runPg pool ensureAttestSchema
          runAttest pool runMigrations

          attest <- tablesIn pool attestSchema
          assertEqual "every projection table is in palmares_attest" (length chainSyncTableNames) (length attest)
          -- Intersected, not compared to empty: `public` legitimately holds db-sync's own tables
          -- (Test.Pg applies its skeleton there), and `palmares` holds the governance views in a
          -- real deployment. What must be empty is OUR names appearing in either.
          ours <- pure (map T.toLower chainSyncTableNames)
          palmares <- tablesIn pool "palmares"
          public <- tablesIn pool "public"
          assertEqual "none leaked into palmares" [] (filter (`elem` ours) palmares)
          assertEqual "none leaked into public" [] (filter (`elem` ours) public),
      -- The old behaviour, pinned — because `src/test/CLAUDE.md` asks every inherited fix for a test
      -- that fails on it, and here the fix is one `SET LOCAL`, so the only way to show it is
      -- load-bearing is to run the migration WITHOUT it and watch the tables land in the wrong
      -- place. This is what the service did before `runAttest` existed.
      testCase "without the pin the tables land in palmares — which is why runAttest exists" $
        withScratchDb $ \pool -> do
          runPg pool $ do
            rawExecute "CREATE SCHEMA IF NOT EXISTS palmares" []
            rawExecute "SET search_path TO palmares, palmares_attest, public" []
          runPg pool ensureAttestSchema
          -- runPg, not runAttest: no SET LOCAL, so `palmares` is still first on the path.
          runPg pool runMigrations
          wrong <- tablesIn pool "palmares"
          right <- tablesIn pool attestSchema
          assertEqual "every projection table went to palmares" (length chainSyncTableNames) (length wrong)
          assertEqual "and none to palmares_attest" [] right,
      -- The consequence, asserted directly rather than inferred from the schema name.
      testCase "the projections survive DROP SCHEMA palmares CASCADE — a query-api boot" $
        withScratchDb $ \pool -> do
          runPg pool $ rawExecute "CREATE SCHEMA IF NOT EXISTS palmares" []
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          before <- tablesIn pool attestSchema
          assertBool "there are tables to lose" (not (null before))
          -- Verbatim what sql/000_schema.sql's first statement does, on every boot of the read API.
          runPg pool $ rawExecute "DROP SCHEMA IF EXISTS palmares CASCADE" []
          after <- tablesIn pool attestSchema
          assertEqual "every projection table is still there" before after,
      -- runAttest is the only thing standing between the entities and the wrong schema, so what it
      -- sets is worth pinning. SET LOCAL, not SET: the pool reuses connections, and a path left
      -- behind would follow whatever ran next on that connection.
      testCase "runAttest pins search_path to palmares_attest, and only for its own transaction" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          [Single (inside :: T.Text)] <- runAttest pool (rawSql "SELECT current_schema()::text" [])
          inside @?= attestSchema
          -- A later transaction on the same pool must not inherit it.
          [Single (outside :: T.Text)] <- runPg pool (rawSql "SELECT current_schema()::text" [])
          assertBool "the path did not leak onto the pooled connection" (outside /= attestSchema),
      -- chainSyncTableNames drives wipeChainSyncTablesRaw, so a name missing from it is a table the
      -- version-bump wipe silently leaves behind for migrateAll to trip over.
      testCase "chainSyncTableNames lists exactly the tables the migration creates" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          created <- tablesIn pool attestSchema
          created @?= sort (map T.toLower chainSyncTableNames),
      -- The schema-version TRIPWIRE, and it is honest about being one rather than a proof.
      --
      -- `currentSchemaVersion` is what makes a deployed attest-sync wipe and re-sync, and a column
      -- added without bumping it leaves a running service migrating a new column onto rows that can
      -- never hold a value for it — the three columns below are read off the datum, so they cannot
      -- be backfilled from the database, only from the chain. Nothing in the suite noticed that
      -- before this test: the version is a bare constant and no assertion mentioned it.
      --
      -- So the count is deliberate. Adding a column fails HERE, next to the version it owes.
      testCase "attestation_projection's columns and currentSchemaVersion describe the same schema" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          cols <- columnsIn pool attestSchema "attestation_projection"
          let shown = show cols
          assertBool ("attestation_kind missing: " <> shown) ("attestation_kind" `elem` cols)
          assertBool ("claimed_period_from missing: " <> shown) ("claimed_period_from" `elem` cols)
          assertBool ("claimed_period_to missing: " <> shown) ("claimed_period_to" `elem` cols)
          assertEqual
            ("column count changed — bump currentSchemaVersion with the schema: " <> shown)
            17
            (length cols)
          assertEqual "currentSchemaVersion is the version this column set belongs to" 2 currentSchemaVersion
    ]
  where
    columnsIn :: ConnectionPool -> T.Text -> T.Text -> IO [T.Text]
    columnsIn pool schema table =
      map unSingle
        <$> runPg
          pool
          ( rawSql
              "SELECT column_name::text FROM information_schema.columns \
              \WHERE table_schema = ? AND table_name = ? ORDER BY column_name"
              [toPersistValue schema, toPersistValue table]
          )

    tablesIn :: ConnectionPool -> T.Text -> IO [T.Text]
    tablesIn pool schema =
      map unSingle
        <$> runPg
          pool
          ( rawSql
              "SELECT table_name::text FROM information_schema.tables \
              \WHERE table_schema = ? AND table_type = 'BASE TABLE' ORDER BY table_name"
              [toPersistValue schema]
          )
