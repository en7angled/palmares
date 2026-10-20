{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The governance activity feed (D-19).
--
-- Seeded rather than measured, because the properties under test are the cursor's totality and
-- the completeness of the kind set, and only a seeded corpus can contain every kind: preprod has
-- never recorded a committee resignation and has never enacted a treasury withdrawal, so a
-- @DISTINCT event_type = 13@ assertion against the real database would be unfalsifiable. The
-- real-corpus counterpart is sql/checks/060_activity.sql, which asserts the per-kind counts and
-- the uniqueness over 3.9 M rows.
module UnitTests.Activity (tests) where

import Data.Text (Text)
import Data.Time (UTCTime)
import Database.Persist.Sql (Single (..), rawExecute, rawSql, unSingle)
import Query.Views (applyPalmaresSchema)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "activity feed"
    [ testCase "all thirteen governance kinds are produced" $ withScratchDb $ \pool -> do
        applyPalmaresSchema pool
        runPg pool $ rawExecute seedActivity []
        ks <- runPg pool $ rawSql "SELECT DISTINCT event_type FROM palmares.activity ORDER BY 1" []
        map (unSingle :: Single Text -> Text) ks
          @?= [ "committee_authorized",
                "committee_resigned",
                "delegation_changed",
                "drep_registered",
                "drep_retired",
                "drep_updated",
                "gov_action_dropped",
                "gov_action_enacted",
                "gov_action_expired",
                "gov_action_proposed",
                "gov_action_ratified",
                "treasury_withdrawal_enacted",
                "vote_cast"
              ],
      -- Four components, not three. The real corpus has 108,141 duplicate triples; see the header
      -- of palmares.activity for the two causes and the measurement.
      testCase "the cursor is unique over the whole feed" $ withScratchDb $ \pool -> do
        applyPalmaresSchema pool
        runPg pool $ rawExecute seedActivity []
        [Single (dups :: Int)] <-
          runPg pool $
            rawSql
              "SELECT count(*)::int FROM (SELECT 1 FROM palmares.activity \
              \GROUP BY sort_slot, tx_index, arm, item_index HAVING count(*) > 1) x"
              []
        dups @?= 0,
      -- An epoch-boundary event has no transaction, so it must not pretend to have one. Inventing
      -- a slot or a tx hash for it would put a chain point in the API that does not exist.
      testCase "epoch-boundary events carry a negative tx_index, a null slot and a null tx_hash" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          runPg pool $ rawExecute seedActivity []
          [Single (bad :: Int)] <-
            runPg pool $
              rawSql
                "SELECT count(*)::int FROM palmares.activity WHERE event_type IN \
                \('gov_action_ratified','gov_action_enacted','gov_action_expired',\
                \'gov_action_dropped','treasury_withdrawal_enacted') \
                \AND (tx_index NOT IN (-1, -2) OR slot_no IS NOT NULL OR tx_hash IS NOT NULL)"
                []
          bad @?= 0,
      -- The one arm at -2: a treasury payout fires in the same epoch as its action's enactment,
      -- for the same proposal id, so at -1 it would collide on every cursor component.
      testCase "an enacted treasury withdrawal and its action's enactment do not share a cursor" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          runPg pool $ rawExecute seedActivity []
          [Single (ix :: Int)] <-
            runPg pool $
              rawSql "SELECT tx_index FROM palmares.activity WHERE event_type = 'treasury_withdrawal_enacted'" []
          ix @?= (-2),
      testCase "an epoch-boundary event's time is the first block of its epoch" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          runPg pool $ rawExecute seedActivity []
          [Single (t :: UTCTime)] <-
            runPg pool $
              rawSql "SELECT block_time FROM palmares.activity WHERE event_type = 'gov_action_ratified'" []
          t @?= read "2026-10-18 00:00:00 UTC"
    ]

-- | A corpus that contains every kind at least once.
--
-- Shape notes, which cannot live inside the string itself: a Haskell string gap may contain only
-- whitespace, and the SQL has no newlines so a @--@ comment would swallow the rest of a statement.
--
--   * the three DRep certificate kinds come off one arm, keyed by deposit: > 0 register,
--     NULL update, < 0 retire;
--   * four proposals, one per lifecycle outcome, with the ratified one also enacted as on preprod;
--   * TWO VOTES IN ONE TRANSACTION, both with @index = 0@. That is the shape that makes
--     @voting_procedure.index@ useless as a cursor component, and it is real preprod data, not a
--     contrived case — the CC stress test produced it 648,000 times over;
--   * epoch 320 gets two blocks so that "the first block of the epoch" is a real choice rather
--     than the only one: block 10 is first by id and carries the time the last test asserts;
--   * no @epoch_param@ row, deliberately. It has ~20 NOT NULL columns and the feed does not read
--     it: only @action_window.drep_votable@ does, through an EXISTS that is simply false without
--     one, and @palmares.activity@ never filters on that.
seedActivity :: Text
seedActivity =
  "INSERT INTO public.block (id, hash, epoch_no, slot_no, epoch_slot_no, block_no, slot_leader_id, size, \"time\", tx_count, proto_major, proto_minor) VALUES \
  \ (1,'\\x01',300,1000,0,1,1,1,'2026-10-01 00:00:00',1,10,0), \
  \ (2,'\\x02',305,2000,0,2,1,1,'2026-10-05 00:00:00',1,10,0), \
  \ (10,'\\x0a',320,9000,0,10,1,1,'2026-10-18 00:00:00',0,10,0), \
  \ (11,'\\x0b',320,9100,1,11,1,1,'2026-10-18 06:00:00',0,10,0), \
  \ (12,'\\x0c',321,9500,0,12,1,1,'2026-10-19 00:00:00',0,10,0), \
  \ (13,'\\x0d',322,9900,0,13,1,1,'2026-10-20 00:00:00',0,10,0); \
  \ INSERT INTO public.tx (id, hash, block_id, block_index, out_sum, fee, size, valid_contract, script_size) VALUES \
  \ (1,'\\xaa',1,0,0,0,1,TRUE,0), \
  \ (2,'\\xbb',2,0,0,0,1,TRUE,0); \
  \ INSERT INTO public.stake_address (id, hash_raw, view) VALUES \
  \ (1,'\\xe0aa','stake_test1aa'), (2,'\\xe0bb','stake_test1bb'); \
  \ INSERT INTO public.drep_hash (id, raw, view, has_script) VALUES \
  \ (1,'\\xd1','drep1d1',FALSE), (2,'\\xd2','drep1d2',FALSE); \
  \ INSERT INTO public.committee_hash (id, raw, has_script) VALUES \
  \ (1,'\\xc1',TRUE), (2,'\\xc2',TRUE); \
  \ INSERT INTO public.drep_registration (id, tx_id, cert_index, deposit, drep_hash_id) VALUES \
  \ (1,1,0,500000000,1), (2,1,1,NULL,1), (3,2,0,-500000000,1); \
  \ INSERT INTO public.delegation_vote (id, addr_id, cert_index, drep_hash_id, tx_id) VALUES \
  \ (1,1,2,1,1); \
  \ INSERT INTO public.committee_registration (id, tx_id, cert_index, cold_key_id, hot_key_id) VALUES \
  \ (1,1,3,1,2); \
  \ INSERT INTO public.committee_de_registration (id, tx_id, cert_index, cold_key_id) VALUES \
  \ (1,2,1,1); \
  \ INSERT INTO public.gov_action_proposal (id, tx_id, index, deposit, return_address, expiration, type, description, ratified_epoch, enacted_epoch, dropped_epoch, expired_epoch) VALUES \
  \ (1,1,0,100000000,1,307,'TreasuryWithdrawals','{}'::jsonb,320,320,NULL,NULL), \
  \ (2,1,1,100000000,1,307,'InfoAction','{}'::jsonb,NULL,NULL,NULL,321), \
  \ (3,1,2,100000000,1,307,'ParameterChange','{}'::jsonb,NULL,NULL,322,NULL), \
  \ (4,2,0,100000000,1,330,'InfoAction','{}'::jsonb,NULL,NULL,NULL,NULL); \
  \ INSERT INTO public.treasury_withdrawal (id, gov_action_proposal_id, stake_address_id, amount) VALUES \
  \ (1,1,2,42000000); \
  \ INSERT INTO public.voting_procedure (id, tx_id, index, gov_action_proposal_id, voter_role, drep_voter, vote) VALUES \
  \ (1,1,0,2,'DRep',1,'Yes'), \
  \ (2,1,0,2,'DRep',2,'No');"
