{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the (role, action type) → threshold column table.
--
-- The table is ledger law, so these are not tests of a judgement but of a transcription — which
-- is exactly the kind of thing that goes wrong silently. The exhaustiveness test is the one that
-- earns its keep: it fails when a db-sync upgrade adds a @param_proposal@ column nobody
-- classified, which would otherwise make a ParameterChange's threshold quietly come back as
-- \"no groups touched\".
module UnitTests.GovThresholds (govThresholdsTests) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Types (GovActionType (..), VoterRole (..))
import Query.Thresholds
import Test.Tasty
import Test.Tasty.HUnit

-- | @param_proposal@'s columns at db-sync 13.7.1.0, read off the real table.
--
-- Hard-coded rather than queried, deliberately: this test must fail on a laptop with no db-sync,
-- and the point of it is to notice when the upstream table changes — which it cannot do if it
-- reads the table it is checking.
paramProposalColumns :: [Text]
paramProposalColumns =
  T.words
    "id epoch_no key min_fee_a min_fee_b max_block_size max_tx_size max_bh_size key_deposit \
    \pool_deposit max_epoch optimal_pool_count influence monetary_expand_rate \
    \treasury_growth_rate decentralisation entropy protocol_major protocol_minor min_utxo_value \
    \min_pool_cost cost_model_id price_mem price_step max_tx_ex_mem max_tx_ex_steps \
    \max_block_ex_mem max_block_ex_steps max_val_size collateral_percent max_collateral_inputs \
    \registered_tx_id coins_per_utxo_size pvt_motion_no_confidence pvt_committee_normal \
    \pvt_committee_no_confidence pvt_hard_fork_initiation dvt_motion_no_confidence \
    \dvt_committee_normal dvt_committee_no_confidence dvt_update_to_constitution \
    \dvt_hard_fork_initiation dvt_p_p_network_group dvt_p_p_economic_group \
    \dvt_p_p_technical_group dvt_p_p_gov_group dvt_treasury_withdrawal committee_min_size \
    \committee_max_term_length gov_action_lifetime gov_action_deposit drep_deposit drep_activity \
    \pvtpp_security_group min_fee_ref_script_cost_per_byte"

govThresholdsTests :: TestTree
govThresholdsTests =
  testGroup
    "threshold columns"
    [ testCase "DRep column per action type" $
        map
          (thresholdColumnFor DRep)
          [NoConfidence, NewCommittee, NewConstitution, HardForkInitiation, TreasuryWithdrawals, InfoAction]
          @?= [ Just "dvt_motion_no_confidence",
                Just "dvt_committee_normal",
                Just "dvt_update_to_constitution",
                Just "dvt_hard_fork_initiation",
                Just "dvt_treasury_withdrawal",
                Nothing
              ],
      testCase "SPO column per action type; two types have none" $
        map
          (thresholdColumnFor SPO)
          [NoConfidence, NewCommittee, NewConstitution, HardForkInitiation, TreasuryWithdrawals, InfoAction]
          @?= [ Just "pvt_motion_no_confidence",
                Just "pvt_committee_normal",
                Nothing,
                Just "pvt_hard_fork_initiation",
                Nothing,
                Nothing
              ],
      -- The one column a pvt_% prefix scan silently misses: db-sync spells it without the
      -- separator, and pvt_pp_security_group does not exist.
      testCase "the SPO security-group column is pvtpp_security_group" $
        thresholdColumnFor SPO ParameterChange @?= Just "pvtpp_security_group",
      -- Driven by the table itself, so it cannot encode a guessed membership.
      testCase "the SPO security-group threshold applies iff a securityGroupColumns column is touched" $
        ( spoParamChangeApplies [],
          all (spoParamChangeApplies . (: [])) securityGroupColumns,
          spoParamChangeApplies ["drep_deposit"] -- governance group, never security group
        )
          @?= (False, True, False),
      -- Every security-group column must also be a classified parameter, or the two tables
      -- disagree about what a parameter is.
      testCase "every security-group column is in paramGroupColumns" $
        [c | c <- securityGroupColumns, lookup c paramGroupColumns == Nothing] @?= [],
      testCase "the CC never has a dvt_/pvt_ threshold: it has a quorum" $
        map
          (thresholdColumnFor ConstitutionalCommittee)
          [NoConfidence, NewCommittee, InfoAction, ParameterChange]
          @?= [Nothing, Nothing, Nothing, Nothing],
      -- One per group. The plan's own vector for this case used max_tx_ex_mem as the technical
      -- example; CIP-1694 puts the execution-unit LIMITS in the network group (see the next
      -- case), so collateral_percent stands in — it is technical, alongside a0, eMax, nOpt and
      -- costModels.
      testCase "touched param_proposal columns map to CIP-1694 groups" $
        map
          (`lookup` paramGroupColumns)
          ["max_block_size", "min_fee_a", "collateral_percent", "drep_deposit"]
          @?= [ Just "dvt_p_p_network_group",
                Just "dvt_p_p_economic_group",
                Just "dvt_p_p_technical_group",
                Just "dvt_p_p_gov_group"
              ],
      -- max_tx_ex_mem is a NETWORK parameter, not a technical one: CIP-1694 puts the execution
      -- unit LIMITS in the network group and their PRICES in the economic group. Getting this
      -- backwards is the most likely transcription error in the table, so it is asserted.
      testCase "execution units: limits are network, prices are economic" $
        map
          (`lookup` paramGroupColumns)
          ["max_tx_ex_mem", "max_block_ex_steps", "price_mem", "price_step"]
          @?= [ Just "dvt_p_p_network_group",
                Just "dvt_p_p_network_group",
                Just "dvt_p_p_economic_group",
                Just "dvt_p_p_economic_group"
              ],
      testCase "the DRep parameter_change threshold is the max over touched groups" $
        ( drepParamChangeThreshold ["max_block_size", "min_fee_a"],
          drepParamChangeThreshold [],
          -- one group gives the bare column, which a reader can look up directly
          drepParamChangeThreshold ["max_block_size", "max_tx_size"]
        )
          @?= ( Just "greatest(dvt_p_p_network_group, dvt_p_p_economic_group)",
                Nothing,
                Just "dvt_p_p_network_group"
              ),
      -- Deterministic: two proposals touching the same groups must produce the same expression,
      -- whatever order their columns arrive in.
      testCase "the group order is fixed, so the expression is deterministic" $
        drepParamChangeThreshold ["drep_deposit", "min_fee_a", "max_block_size"]
          @?= Just "greatest(dvt_p_p_network_group, dvt_p_p_economic_group, dvt_p_p_gov_group)",
      -- THE test of this module. A db-sync upgrade that adds a parameter column must fail here
      -- rather than make drepParamChangeThreshold return Nothing for a proposal that touches it.
      testCase "paramGroupColumns and unmappedParamColumns cover param_proposal exactly" $ do
        let classified = map fst paramGroupColumns <> map fst unmappedParamColumns
        assertEqual
          "a param_proposal column is classified by neither table"
          []
          [c | c <- paramProposalColumns, c `notElem` classified]
        assertEqual
          "a classified column does not exist in param_proposal"
          []
          [c | c <- classified, c `notElem` paramProposalColumns]
        assertEqual "a column is classified twice" (sort classified) (sort (unique classified))
    ]
  where
    unique = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
