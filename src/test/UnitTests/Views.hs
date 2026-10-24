{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the @palmares@ schema bootstrap: that it applies, that applying it twice is a
-- no-op, that the embedded file set is exactly the four files in lexical order, and that a
-- failing statement anywhere in the set leaves the previous schema intact.
module UnitTests.Views (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Database.Persist.Sql (ConnectionPool, Single (..), SqlPersistT, rawExecute, rawSql)
import Palmares.Metrics.Catalog (catalogJson, metricSql)
import Query.Views (applyPalmaresSchema, applySchemaSql, hasStatement, palmaresSqlFiles)
import Test.Pg (runPg, withScratchDb)
-- `after` is tasty's dependency-ordering combinator and nothing here uses it, while three cases
-- below bind an oid snapshot called `after` beside a `before`. Hidden rather than renamed, the same
-- choice `UnitTests.Projections` and `UnitTests.AttestSchema` make.
import Test.Tasty hiding (after)
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "palmares schema bootstrap"
    [ -- __CABAL DOES NOT TRACK `embedFile` DEPENDENCIES under this toolchain, measured.__ Editing
      -- one line of `sql/030_metrics.sql` recompiled nothing — `Query/Views.o` kept its old mtime
      -- and the test binary kept the old bytes — so the whole SQL-backed half of the suite stayed
      -- green against DDL that was no longer in the tree. `touch`ing the module does not help
      -- either, because GHC hashes sources; only a real source change does.
      --
      -- CI is worse: its `dist-newstyle` cache key hashes `cabal.project`, `cabal.project.freeze`
      -- and `palmares.cabal` and nothing else, so a pull request touching only `sql/**` or
      -- `resources/**` gets an exact cache hit and every Haskell gate runs the previous version —
      -- including `admin write-metrics-doc`, whose "docs are not stale" diff then compares the old
      -- embed against the old document and passes.
      --
      -- This case closes it from the inside: the comparison happens at RUN time against the working
      -- tree, so a binary built from stale embeds fails here with the two byte strings differing.
      -- It cannot be defeated by the staleness it detects.
      testCase "every embedded file is the file on disk (cabal does not track embedFile deps)" $ do
        let embeds =
              [("sql/" <> n, b) | (n, b) <- palmaresSqlFiles]
                <> [("resources/metrics/" <> n, b) | (n, b) <- metricSql]
                <> [("resources/metric-formulas.json", catalogJson)]
        forM_ embeds $ \(path, embedded) -> do
          onDisk <- BS.readFile path
          assertEqual
            (path <> ": the binary's embed is stale — rebuild the test suite (cabal did not notice this file changed)")
            onDisk
            embedded,
      testCase "applies, and applies again (DROP SCHEMA CASCADE makes it idempotent)" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          applyPalmaresSchema pool
          [Single (n :: Int)] <-
            runPg pool $ rawSql "SELECT count(*)::int FROM pg_namespace WHERE nspname = 'palmares'" []
          n @?= 1,
      -- `GV-01`. The rebuild is atomic, so the outage was never about visibility: @DROP@ takes an
      -- AccessExclusiveLock on every object, so readers blocked for the duration — a read outage per
      -- restart once there is more than one replica, and a rolling deploy is nothing but restarts.
      --
      -- What the fingerprint buys is that an ordinary restart does no DDL at all. Asserted by the
      -- OBJECT IDENTITY of a view: a rebuild drops and recreates it, which gives it a new oid, so an
      -- unchanged oid across a second boot is proof the DDL did not run. Counting schemas (the case
      -- above) could not tell a skip from a rebuild — both leave exactly one.
      testCase "a second boot with unchanged DDL does NOT rebuild (GV-01)" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          before <- someViewOid pool
          applyPalmaresSchema pool
          after <- someViewOid pool
          assertEqual "the view was not dropped and recreated" before after,
      -- And the converse, without which the gate could simply be "never rebuild": a fingerprint that
      -- does not match the DDL must force the rebuild. Corrupting the stored value is the honest way
      -- to simulate a DDL change, because editing `palmaresSqlFiles` is a compile-time matter.
      testCase "a fingerprint that does not match forces the rebuild (GV-01)" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          before <- someViewOid pool
          runPg pool $ rawExecute "UPDATE palmares.schema_fingerprint SET fingerprint = 'stale'" []
          applyPalmaresSchema pool
          after <- someViewOid pool
          assertBool "the view WAS dropped and recreated" (before /= after),
      -- A boot that finds no fingerprint table at all — the upgrade path from any database built
      -- before this change — must rebuild rather than assume it is current.
      testCase "a schema with no fingerprint table is rebuilt, not trusted (GV-01)" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          before <- someViewOid pool
          runPg pool $ rawExecute "DROP TABLE palmares.schema_fingerprint" []
          applyPalmaresSchema pool
          after <- someViewOid pool
          assertBool "the view WAS dropped and recreated" (before /= after),
      testCase "every file in palmaresSqlFiles is applied, in lexical order" $
        map fst palmaresSqlFiles
          @?= ["000_schema.sql", "010_gov_views.sql", "020_views.sql", "030_metrics.sql", "040_grants.sql"],
      -- The grants must be the LAST file, not merely present: `GRANT ... ON ALL TABLES` resolves to
      -- the relations that exist when it runs, so the same statement one file earlier would miss
      -- every object `030_metrics.sql` creates — including the matview the DRep list reads.
      testCase "the grants are the last file in the set" $
        fst (last palmaresSqlFiles) @?= "040_grants.sql",
      testCase "a comment-only file is a stub and is skipped, not executed" $ do
        hasStatement "-- nothing here yet\n" @?= False
        hasStatement "   \n\n-- still nothing\n   \n" @?= False
        hasStatement "-- a header\nCREATE SCHEMA x;\n" @?= True
        hasStatement "CREATE SCHEMA x; -- trailing comment\n" @?= True,
      -- Which files are stubs changes as later tasks fill them, so the assertion is the
      -- invariant and not today's snapshot: 000 is never skipped (nothing else can run without
      -- the schema), and filtering never reorders.
      testCase "000_schema.sql is always applied, and filtering preserves order" $ do
        let applied = map fst (filter (hasStatement . snd) palmaresSqlFiles)
        assertBool "000_schema.sql must never be skipped" ("000_schema.sql" `elem` applied)
        applied @?= filter (`elem` applied) (map fst palmaresSqlFiles),
      -- The regression this exists for: before `040_grants.sql`, the boot set granted nothing at
      -- all, so the two-role deployment served 500s on every governance route the first time
      -- query-api restarted. `DROP SCHEMA palmares CASCADE` takes the privileges with the objects,
      -- which is why the SECOND boot is the one that matters and why the assertion is made after it.
      testCase "the boot grants the serving role usage on the schema and select on everything in it" $
        withScratchDb $ \pool -> do
          -- Roles are cluster-wide, so the test creates the one it needs rather than assuming the
          -- server has it. No LOGIN and no password: this is a privilege check, not a connection.
          runPg pool $
            rawExecute
              "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'palmares_ro') \
              \THEN CREATE ROLE palmares_ro; END IF; END $$"
              []
          applyPalmaresSchema pool
          applyPalmaresSchema pool
          [Single (usage :: Bool)] <-
            runPg pool $ rawSql "SELECT has_schema_privilege('palmares_ro', 'palmares', 'USAGE')" []
          assertBool "palmares_ro must have USAGE on schema palmares" usage
          -- Every view and matview, not a named one: a grant that covered the views and missed the
          -- matview would pass a spot check and still break the DRep list.
          [Single (selectable :: Bool)] <-
            runPg pool $
              rawSql
                "SELECT coalesce(bool_and(has_table_privilege('palmares_ro', c.oid, 'SELECT')), false) \
                \FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
                \WHERE n.nspname = 'palmares' AND c.relkind IN ('v', 'm')"
                []
          assertBool "palmares_ro must have SELECT on every view and matview in palmares" selectable,
      -- The other half of that grant's contract, and it cannot be tested by removing the role —
      -- roles are cluster-wide, so a test that dropped `palmares_ro` would race the one above.
      -- What is pinned instead is the guard itself: the single-role deployment has no `palmares_ro`
      -- (PALMARES_PG_OWNER_CONN_STR defaults to PG_CONN_STR), and an unguarded GRANT would abort
      -- the boot transaction with `role "palmares_ro" does not exist` and `die` the process.
      testCase "the grants are guarded on the role existing, so a single-role deployment still boots" $ do
        let grants = maybe "" decodeUtf8 (lookup "040_grants.sql" palmaresSqlFiles)
        assertBool "040_grants.sql must test pg_roles before granting" ("FROM pg_roles" `T.isInfixOf` grants)
        assertBool "040_grants.sql must guard with IF EXISTS" ("IF EXISTS" `T.isInfixOf` grants)
        assertBool "040_grants.sql must never create a role" (not ("CREATE ROLE" `T.isInfixOf` grants)),
      testCase "a failing statement rolls the whole set back — the previous schema survives" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          -- A marker object, so "the previous schema survived" is a positive assertion and not
          -- just "the count is still zero" (the stub files create nothing yet).
          runPg pool $ rawExecute "CREATE VIEW palmares.marker AS SELECT 1 AS one" []
          [Single (relsBefore :: Int)] <- runPg pool countPalmaresRelations
          r <-
            try @SomeException $
              runPg pool (applySchemaSql [("999_bad.sql", "DROP SCHEMA palmares CASCADE; SELECT 1/0;")])
          assertBool "the bad set must fail" (isLeft r)
          [Single (relsAfter :: Int)] <- runPg pool countPalmaresRelations
          relsAfter @?= relsBefore
          assertBool "the marker view must still be there" (relsBefore >= 1)
    ]
  where
    countPalmaresRelations :: SqlPersistT IO [Single Int]
    countPalmaresRelations =
      rawSql
        "SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
        \WHERE n.nspname = 'palmares'"
        []

-- | The oid of one object in the schema, as a rebuild detector: @DROP SCHEMA CASCADE@ gives every
-- recreated object a new oid, so a stable oid means the DDL did not run.
someViewOid :: ConnectionPool -> IO Int
someViewOid pool = do
  rows <-
    runPg pool $
      rawSql
        "SELECT c.oid::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
        \WHERE n.nspname = 'palmares' ORDER BY c.relname LIMIT 1"
        []
  case rows of
    [Single oid] -> pure oid
    _ -> assertFailure "the palmares schema holds no objects at all" >> pure 0
