{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The gate behind README §1: the numbers the API serves are the numbers the published formulas
-- compute (@GV-03@ / @DC-01@).
--
-- Five of the six DRep metrics are NOT executed from the catalog. They are read out of
-- @palmares.drep_metrics@, which the matview's own header calls "a second implementation of the
-- same arithmetic" — batched over all DReps because a @LATERAL@ per DRep would pay a 3.2 M-row
-- pass 812 times. That is a defensible engineering choice and an undefended promise: two
-- implementations drift, and this one HAD drifted. @030_metrics.sql@ counted @count(*)@ after a
-- @LEFT JOIN@ onto every vote row, so a DRep that re-voted on a settled action had its
-- @eligible_actions@ inflated and its @participation_rate@ deflated, for as long as the view has
-- existed. Nothing failed, because the only agreement check (@sql\/checks\/070_drep_metrics.sql@)
-- ran by hand, against preprod, for one pinned credential.
--
-- __So this test compares the served response, not the matview.__ It calls
-- 'Query.Gov.drepMetricsQuery' — the statement @GET \/drep\/{id}\/metrics@ runs — and then runs
-- each published formula by @formula_id@ through 'Test.Metrics.runMetric'. Nothing here re-types a
-- formula, which is what keeps it from being a test of itself. It also covers the THIRD copy:
-- @votes_by_type@ is computed in Haskell inside @drepMetricsQuery@, not in the matview at all.
--
-- __Seeded, not measured, and that is the point.__ 'UnitTests.MetricFixture' already compares the
-- catalog against a caught-up preprod database, which takes seven hours to build and therefore
-- cannot run in CI. This corpus is four blocks and nine rows, so it runs everywhere — and it
-- contains the shapes the real corpus has and an empty database does not: a re-voted action, a
-- settled action nobody voted on, an action still open, and a registered DRep that never voted.
-- The first case below asserts those shapes are still there, because an agreement over an empty
-- corpus is two zeroes agreeing.
--
-- @delegator_retention_rate_v1@ is absent on purpose: it is the one formula the server already
-- executes verbatim (@Gov.hs@'s @delegatorStatsQuery@), so there is no second implementation to
-- compare it against.
module UnitTests.MetricAgreement (tests) where

import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Database.Persist (PersistValue (PersistInt64))
import Database.Persist.Sql (ConnectionPool, Single (..), rawExecute, rawSql)
import Palmares.DomainTypes.Transfer.QueryResponses (DRepMetrics (..), TypeBreakdown (..))
import Query.Gov (drepMetricsQuery)
import Query.Refresh (refreshDRepMetrics)
import Query.Views (applyPalmaresSchema)
import Test.Metrics (runMetric)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "metric agreement (seeded corpus)"
    [ testCase "the corpus still has the four shapes the agreement needs" $ withScratchDb $ \pool -> do
        pool' <- seeded pool
        -- (1) A re-voted (DRep, action) pair. This is the fan-out that made the two
        -- implementations disagree; without it the comparison below passes with count(*) too.
        [Single (revoted :: Int)] <-
          runPg pool' $
            rawSql
              "SELECT count(*)::int FROM ( \
              \  SELECT drep_voter_id, gov_action_id FROM palmares.vote \
              \  WHERE voter_role = 'DRep' GROUP BY 1, 2 HAVING count(*) > 1 ) q"
              []
        assertBool "no re-voted action in the corpus" (revoted >= 1)
        -- (2) A DRep with a non-empty denominator and no votes: participation 0, which is a
        -- different published statement from NULL.
        [Single (silent :: Int)] <-
          countIn pool' "eligible_actions > 0 AND votes_cast = 0"
        assertBool "no registered-but-silent DRep in the corpus" (silent >= 1)
        -- (3) A rate strictly between the two trivial answers, so a formula that returned either
        -- constant would be caught.
        [Single (partial :: Int)] <-
          countIn pool' "participation_rate > 0 AND participation_rate < 1"
        assertBool "no partial participation rate in the corpus" (partial >= 1)
        -- (4) An action still open: it must stay OUT of the denominator and IN
        -- open_actions_unvoted, and those are two different columns to get wrong.
        [Single (open :: Int)] <- countIn pool' "open_actions_unvoted > 0"
        assertBool "no open unvoted action in the corpus" (open >= 1),
      testCase "every number the metrics route serves equals its published formula, for every DRep" $
        withScratchDb $ \pool -> do
          pool' <- seeded pool
          ids <- runPg pool' $ rawSql "SELECT drep_hash_id FROM palmares.drep_metrics ORDER BY 1" []
          let dreps = [d | Single (d :: Int64) <- ids]
          assertBool "the corpus must produce matview rows" (not (null dreps))
          mapM_ (agree pool') dreps
    ]

-- | Apply the schema, seed, and populate the matview the way production does.
seeded :: ConnectionPool -> IO ConnectionPool
seeded pool = do
  applyPalmaresSchema pool
  runPg pool $ rawExecute seedCorpus []
  -- refreshDRepMetrics, not a second applyPalmaresSchema: refreshing is what the production
  -- thread does, and the bootstrap no longer doubles as a refresh (GV-01).
  refreshDRepMetrics pool >>= either (assertFailure . ("refresh failed: " <>) . show) pure
  pure pool

countIn :: ConnectionPool -> Text -> IO [Single Int]
countIn pool predicate =
  runPg pool $ rawSql ("SELECT count(*)::int FROM palmares.drep_metrics WHERE " <> predicate) []

-- | One DRep: the served response against the five formulas that produce it.
agree :: ConnectionPool -> Int64 -> IO ()
agree pool d = do
  served <-
    runPg pool (drepMetricsQuery d)
      >>= maybe (assertFailure ("the metrics route serves nothing for drep " <> show d)) pure
  -- The epoch comes from the response, not from the seed: every number in the row is "as of" that
  -- epoch, so binding a different one here would compare two different measurements.
  let params = [PersistInt64 d, PersistInt64 (fromIntegral (drepMetricsAsOfEpoch served))]
      at what = "drep " <> show d <> ": " <> what

  [(Single elig, Single cast, Single rate, Single openUnvoted)] <-
    runMetric pool "participation_rate_v1" params
  assertEqual (at "eligible_actions") (elig :: Int) (drepMetricsEligibleActions served)
  assertEqual (at "votes_cast") (cast :: Int) (drepMetricsVotesCast served)
  assertEqual (at "open_actions_unvoted") (openUnvoted :: Int) (drepMetricsOpenActionsUnvoted served)
  sameRate (at "participation_rate") (rate :: Maybe Double) (drepMetricsParticipationRate served)

  [(Single verified, Single inline, Single unverified, Single pending, Single absent, Single cip100, Single ratRate)] <-
    runMetric pool "rationale_rate_v1" params
  assertEqual (at "rationale_verified") (verified :: Int) (drepMetricsRationaleVerified served)
  assertEqual (at "rationale_inline") (inline :: Int) (drepMetricsRationaleInline served)
  assertEqual (at "rationale_unverified") (unverified :: Int) (drepMetricsRationaleUnverified served)
  assertEqual (at "rationale_pending") (pending :: Int) (drepMetricsRationalePending served)
  assertEqual (at "rationale_absent") (absent :: Int) (drepMetricsRationaleAbsent served)
  assertEqual (at "rationale_cip100_valid") (cip100 :: Int) (drepMetricsRationaleCip100Valid served)
  sameRate (at "rationale_rate") (ratRate :: Maybe Double) (drepMetricsRationaleRate served)

  [(Single median, Single p90, Single sample)] <-
    runMetric pool "vote_latency_median_hours_v1" params
  sameRate (at "vote_latency_median_hours") (median :: Maybe Double) (drepMetricsVoteLatencyMedianHours served)
  sameRate (at "vote_latency_p90_hours") (p90 :: Maybe Double) (drepMetricsVoteLatencyP90Hours served)
  assertEqual (at "vote_latency_sample") (sample :: Int) (drepMetricsVoteLatencySample served)

  -- The route serves `floor(age_days)::int`, so the comparison floors the formula rather than
  -- demanding the route publish a fraction of a day it never published.
  [Single (days :: Maybe Double)] <- runMetric pool "age_days_v1" params
  assertEqual (at "age_days") (fmap (floor :: Double -> Int) days) (drepMetricsAgeDays served)

  byType <- runMetric pool "votes_by_type_v1" params
  let fromCatalog =
        sortOn
          fst
          [ (t, (e, c, y, n, a, r))
          | ( Single (t :: Text),
              Single (e :: Int),
              Single (c :: Int),
              Single (y :: Int),
              Single (n :: Int),
              Single (a :: Int),
              Single (r :: Maybe Double)
              ) <-
              byType
          ]
      -- `show` on GovActionType is db-sync's own spelling of the enum, which is what the catalog
      -- statement returns, so the key needs no second mapping table to compare against.
      fromRoute =
        sortOn
          fst
          [ ( tshow gat,
              ( typeBreakdownEligibleActions b,
                typeBreakdownVotesCast b,
                typeBreakdownYes b,
                typeBreakdownNo b,
                typeBreakdownAbstain b,
                typeBreakdownParticipationRate b
              )
            )
          | (gat, b) <- drepMetricsVotesByType served
          ]
  assertEqual (at "votes_by_type keys") (map fst fromCatalog) (map fst fromRoute)
  sequence_
    [ do
        assertEqual (at ("votes_by_type " <> show t)) (e, c, y, n, a) (e', c', y', n', a')
        sameRate (at ("votes_by_type " <> show t <> " participation_rate")) r r'
    | ((t, (e, c, y, n, a, r)), (_, (e', c', y', n', a', r'))) <- zip fromCatalog fromRoute
    ]

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Two published rates agree. Both sides compute @count::float8 \/ count@, so this is comparing
-- the same expression over the same rows — but a float equality that is one ULP out would fail for
-- a reason nobody could act on, so the comparison carries an epsilon. A NULL must still be a NULL:
-- "no data" and "zero" are different statements about a person (3.8).
sameRate :: String -> Maybe Double -> Maybe Double -> IO ()
sameRate what expected actual = case (expected, actual) of
  (Nothing, Nothing) -> pure ()
  (Just a, Just b) ->
    assertBool (what <> ": " <> show a <> " vs " <> show b) (abs (a - b) <= 1e-9)
  _ -> assertFailure (what <> ": " <> show expected <> " vs " <> show actual)

-- | Four blocks, two DReps, five actions, four votes.
--
-- One statement string with no newlines, like the other seeds in this suite: a @--@ comment would
-- swallow the rest of it.
--
-- Every action is an @InfoAction@ because @action_window.drep_votable@ is true for one without
-- consulting @epoch_param@, whose ~20 NOT NULL columns would double the size of this seed to
-- establish a fact the metrics do not read.
--
--   * drep 1 votes on actions 1, 2 and 3 and RE-VOTES on action 1 (two rows, one pair);
--   * action 4 is settled and unvoted, so drep 1's rate is 3\/4 and not 1;
--   * action 5 is still open: out of the denominator, into @open_actions_unvoted@;
--   * drep 2 is registered for the same window and never votes: denominator 4, rate 0;
--   * the final vote on action 1 carries a @data:@ anchor (grade @inline@), the vote on action 2
--     carries a fetchable one with no off-chain row (@pending@), and the vote on action 3 has no
--     anchor at all (@absent@) — so @rationale_rate@ is 1\/2 rather than 0 or 1.
seedCorpus :: Text
seedCorpus =
  "INSERT INTO public.block (id, hash, epoch_no, slot_no, epoch_slot_no, block_no, slot_leader_id, size, \"time\", tx_count, proto_major, proto_minor) VALUES \
  \ (1,'\\x01',300,1000,0,1,1,1,'2026-01-01 00:00:00',1,10,0), \
  \ (2,'\\x02',302,2000,0,2,1,1,'2026-01-03 00:00:00',1,10,0), \
  \ (3,'\\x03',304,3000,0,3,1,1,'2026-01-05 12:00:00',1,10,0), \
  \ (4,'\\x04',320,9000,0,4,1,1,'2026-02-01 00:00:00',0,10,0); \
  \ INSERT INTO public.tx (id, hash, block_id, block_index, out_sum, fee, size, valid_contract, script_size) VALUES \
  \ (1,'\\xaa',1,0,0,0,1,TRUE,0), (2,'\\xbb',2,0,0,0,1,TRUE,0), (3,'\\xcc',3,0,0,0,1,TRUE,0); \
  \ INSERT INTO public.stake_address (id, hash_raw, view) VALUES (1,'\\xe0aa','stake_test1aa'); \
  \ INSERT INTO public.drep_hash (id, raw, view, has_script) VALUES \
  \ (1,'\\xd1','drep1d1',FALSE), (2,'\\xd2','drep1d2',FALSE); \
  \ INSERT INTO public.drep_registration (id, tx_id, cert_index, deposit, drep_hash_id) VALUES \
  \ (1,1,0,500000000,1), (2,1,1,500000000,2); \
  \ INSERT INTO public.gov_action_proposal (id, tx_id, index, deposit, return_address, expiration, type, description, ratified_epoch, enacted_epoch, dropped_epoch, expired_epoch) VALUES \
  \ (1,1,0,100000000,1,307,'InfoAction','{}'::jsonb,NULL,NULL,NULL,307), \
  \ (2,1,1,100000000,1,308,'InfoAction','{}'::jsonb,NULL,NULL,NULL,308), \
  \ (3,1,2,100000000,1,309,'InfoAction','{}'::jsonb,NULL,NULL,NULL,309), \
  \ (4,1,3,100000000,1,310,'InfoAction','{}'::jsonb,NULL,NULL,NULL,310), \
  \ (5,1,4,100000000,1,330,'InfoAction','{}'::jsonb,NULL,NULL,NULL,NULL); \
  \ INSERT INTO public.voting_anchor (id, url, data_hash, type, block_id) VALUES \
  \ (1,'data:application/json,{}','\\xf1','other',1), \
  \ (2,'https://example.invalid/rationale.json','\\xf2','other',1); \
  \ INSERT INTO public.voting_procedure (id, tx_id, index, gov_action_proposal_id, voter_role, drep_voter, vote, voting_anchor_id) VALUES \
  \ (1,2,0,1,'DRep',1,'Yes',NULL), \
  \ (2,3,0,1,'DRep',1,'No',1), \
  \ (3,3,1,2,'DRep',1,'Abstain',2), \
  \ (4,3,2,3,'DRep',1,'Yes',NULL);"
