{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for @palmares.drep_metrics@ and the thread that refreshes it.
--
-- The refresh decision is pure and is tested as such. Everything else needs a real PostgreSQL,
-- because @REFRESH MATERIALIZED VIEW CONCURRENTLY@ is exactly the operation that behaves
-- differently inside a transaction, and that difference is the bug this task exists to avoid.
module UnitTests.Refresh (tests) where

import Data.Either (isLeft)
import Data.Text (Text)
import Database.Persist.Sql (Single (..), rawExecute, rawSql)
import Query.Refresh (RefreshMark (..), readRefreshMark, refreshDRepMetrics, shouldRefresh)
import Query.Views (applyPalmaresSchema)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "drep_metrics refresh"
    [ testCase "refreshes on the first tick, then only when the tip mark changes" $ do
        shouldRefresh Nothing (RefreshMark 100 320) @?= True
        shouldRefresh (Just (RefreshMark 100 320)) (RefreshMark 100 320) @?= False
        shouldRefresh (Just (RefreshMark 100 320)) (RefreshMark 101 320) @?= True
        -- An epoch boundary moves the lifecycle *_epoch columns and drep_distr without inserting
        -- a single new row, so the block number alone would miss it.
        shouldRefresh (Just (RefreshMark 100 320)) (RefreshMark 100 321) @?= True
        -- A rollback moves the mark backwards; inequality catches it without a special case.
        shouldRefresh (Just (RefreshMark 100 320)) (RefreshMark 97 320) @?= True,
      testCase "the matview exists, is populated at boot, and REFRESH CONCURRENTLY works on it" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          r <- refreshDRepMetrics pool
          assertBool ("REFRESH CONCURRENTLY must succeed: " <> show r) (not (isLeft r))
          [Single (n :: Int)] <-
            runPg pool $
              rawSql
                "SELECT count(*)::int FROM pg_matviews \
                \ WHERE schemaname = 'palmares' AND matviewname = 'drep_metrics'"
                []
          n @?= 1
          -- CONCURRENTLY needs the unique index. Assert it here rather than discover it when the
          -- first refresh of a deployed process fails.
          [Single (ix :: Int)] <-
            runPg pool $
              rawSql
                "SELECT count(*)::int FROM pg_indexes \
                \ WHERE schemaname = 'palmares' AND indexname = 'palmares_idx_drep_metrics_pk'"
                []
          ix @?= 1,
      testCase "a failed refresh is returned, never thrown past the loop" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          -- What a db-sync migration's CASCADE does to the matview.
          runPg pool $ rawExecute "DROP MATERIALIZED VIEW palmares.drep_metrics" []
          r <- refreshDRepMetrics pool
          assertBool "must come back as Left, so the thread keeps looping" (isLeft r),
      -- The only test that executes readRefreshMark's statement and the matview's SELECT list.
      -- Without it a typo in either would first show up in a deployed process.
      testCase "no blocks means no mark and no rows; one block gives both" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          markBefore <- readRefreshMark pool
          markBefore @?= Nothing
          [Single (rowsBefore :: Int)] <- runPg pool (rawSql "SELECT count(*)::int FROM palmares.drep_metrics" [])
          rowsBefore @?= 0
          runPg pool $ rawExecute seedTip []
          -- `refreshDRepMetrics` and NOT `applyPalmaresSchema` again, as of `GV-01`. This line used
          -- to re-bootstrap the whole schema to repopulate one matview — the bootstrap doubled as a
          -- refresh because it dropped and recreated everything on every call. It no longer does
          -- (the DDL is fingerprinted), and the two jobs are better apart anyway: refreshing a
          -- matview is what the periodic refresh does in production, so the test now exercises the
          -- production path instead of a side effect of the boot path.
          refreshDRepMetrics pool >>= either (assertFailure . ("refresh failed: " <>) . show) pure
          readRefreshMark pool >>= (@?= Just (RefreshMark 7 320))
          -- One row per real DRep credential, with counters zeroed and rates left NULL: this DRep
          -- registered in epoch 320, so nothing has settled and there is no rate to publish.
          [(Single (elig :: Int), Single (votes :: Int), Single (rate :: Maybe Double), Single (power :: Int))] <-
            runPg pool $
              rawSql
                "SELECT eligible_actions, votes_cast, participation_rate, voting_power::int \
                \ FROM palmares.drep_metrics"
                []
          elig @?= 0
          votes @?= 0
          assertBool "a DRep with nothing to vote on has no rate, not a rate of zero" (rate == Nothing)
          power @?= 0,
      -- __DELETED: "the five rationale grades sum to votes_cast, for every row".__ It was vacuous
      -- and it cannot be made honest here. `seedTip` has no `voting_procedure` rows at all, so the
      -- single matview row carried `votes_cast = 0` with all five grades COALESCEd to 0, and
      -- `0 = 0` holds whether the FILTERs in `sql/030_metrics.sql` are wired correctly or not — it
      -- would also have passed on an empty matview. Proven by mutation: breaking `rationale_inline`
      -- so the grades summed to 2 against `votes_cast = 3` left that case OK, and the only test in
      -- the suite that went red was `UnitTests.MetricAgreement`.
      --
      -- Which is where the property belongs: that module seeds a corpus WITH votes — a re-voter, a
      -- silent DRep, a partial rate — and compares the served response against all five published
      -- formulas. Copying its corpus here to re-prove the same thing would be a second fixture to
      -- keep in step with the first. The honest coverage is one real test, not two cases.
      testCase "an epoch with no votes leaves the grades at zero rather than null" $
        withScratchDb $ \pool -> do
          runPg pool $ rawExecute seedTip []
          applyPalmaresSchema pool
          -- The COALESCE, which this corpus CAN prove: no votes must give 0 and never NULL, because
          -- a NULL would propagate through every sum a consumer builds on these five columns.
          [Single (nulls :: Int)] <-
            runPg pool $
              rawSql
                "SELECT count(*)::int FROM palmares.drep_metrics \
                \ WHERE rationale_verified IS NULL OR rationale_inline IS NULL \
                \    OR rationale_unverified IS NULL OR rationale_pending IS NULL \
                \    OR rationale_absent IS NULL OR votes_cast IS NULL"
                []
          nulls @?= 0
    ]

-- | The smallest chain the matview needs: a tip block, one registered DRep, and the transaction
-- its certificate sits in. The DRep registers in the tip's own epoch, which is what makes the
-- zero-and-NULL assertions above a real case rather than an empty-table artefact.
--
-- One statement string with no newlines, like the other seeds in this suite: a @--@ comment would
-- swallow the rest of it.
seedTip :: Text
seedTip =
  "INSERT INTO public.block (id, hash, epoch_no, slot_no, epoch_slot_no, block_no, slot_leader_id, size, \"time\", tx_count, proto_major, proto_minor) VALUES \
  \ (1,'\\x01',320,9000,0,7,1,1,'2026-10-18 00:00:00',1,10,0); \
  \ INSERT INTO public.tx (id, hash, block_id, block_index, out_sum, fee, size, valid_contract, script_size) VALUES \
  \ (1,'\\xaa',1,0,0,0,1,TRUE,0); \
  \ INSERT INTO public.drep_hash (id, raw, view, has_script) VALUES (1,'\\xd1','drep1d1',FALSE); \
  \ INSERT INTO public.drep_registration (id, tx_id, cert_index, deposit, drep_hash_id) VALUES (1,1,0,500000000,1);"
