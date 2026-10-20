{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @palmares.threshold_map@ is ledger law written down as a table, so it is pinned row by row
-- (D-25). Two things this test exists to catch:
--
--   * @pvtpp_security_group@, which does not share its four siblings' @pvt_@ prefix. A prefix
--     scan in application code misses the one threshold that decides whether an SPO vote on a
--     ParameterChange counts at all.
--   * the NULLs. Each one is a different reason — a quorum rather than a stake fraction, a role
--     that does not vote, an action that is never ratifiable, or a threshold that is a maximum
--     over several columns — and a metric that reads a missing threshold as 0 would report a
--     unanimous vote as having failed.
module UnitTests.ThresholdMap (tests) where

import Data.Text (Text)
import Database.Persist.Sql (Single (..), rawSql)
import Query.Views (applyPalmaresSchema)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testCase "threshold_map is the API contract's static table" $ withScratchDb $ \pool -> do
    applyPalmaresSchema pool
    rows <-
      runPg pool $
        rawSql
          "SELECT action_type::text, voter_role::text, threshold_param \
          \FROM palmares.threshold_map ORDER BY action_type::text, voter_role::text"
          []
    map (\(Single a, Single r, Single p) -> (a :: Text, r :: Text, p :: Maybe Text)) rows
      @?= [ ("HardForkInitiation", "ConstitutionalCommittee", Nothing), -- quorum, not a column
            ("HardForkInitiation", "DRep", Just "dvt_hard_fork_initiation"),
            ("HardForkInitiation", "SPO", Just "pvt_hard_fork_initiation"),
            ("InfoAction", "ConstitutionalCommittee", Nothing),
            ("InfoAction", "DRep", Nothing), -- never ratifiable
            ("InfoAction", "SPO", Nothing),
            ("NewCommittee", "ConstitutionalCommittee", Nothing), -- does not vote on its own replacement
            ("NewCommittee", "DRep", Just "dvt_committee_normal"), -- _normal always, in F1
            ("NewCommittee", "SPO", Just "pvt_committee_normal"),
            ("NewConstitution", "ConstitutionalCommittee", Nothing),
            ("NewConstitution", "DRep", Just "dvt_update_to_constitution"),
            ("NewConstitution", "SPO", Nothing), -- SPOs do not vote on the constitution
            ("NoConfidence", "ConstitutionalCommittee", Nothing), -- does not vote
            ("NoConfidence", "DRep", Just "dvt_motion_no_confidence"),
            ("NoConfidence", "SPO", Just "pvt_motion_no_confidence"),
            ("ParameterChange", "ConstitutionalCommittee", Nothing),
            ("ParameterChange", "DRep", Nothing), -- max over the groups the proposal touches
            ("ParameterChange", "SPO", Just "pvtpp_security_group"), -- NOT pvt_pp_security_group
            ("TreasuryWithdrawals", "ConstitutionalCommittee", Nothing),
            ("TreasuryWithdrawals", "DRep", Just "dvt_treasury_withdrawal"),
            ("TreasuryWithdrawals", "SPO", Nothing)
          ]
