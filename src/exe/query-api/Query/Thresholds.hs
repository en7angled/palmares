{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Which @epoch_param@ threshold decides a given (voter role, governance action type).
--
-- A static table, not a derivation, and a named deliverable with its own test (D-25) because
-- \"the @dvt_*@ or @pvt_*@ column for the action type\" is not a function of the action type.
-- Three of the awkward cases are what make that true:
--
--   * the constitutional committee has NO stake threshold at all — it ratifies by a quorum of its
--     members, so every cell in its row is @Nothing@ and that is the answer, not a gap;
--   * two action types have no SPO threshold, because SPOs do not vote on them;
--   * @ParameterChange@ has no single DRep threshold: it is the MAXIMUM over the parameter groups
--     the proposal actually touches, which is a property of the proposal rather than of its type.
--
-- The @_normal@ committee column is always the one reported. The @_no_confidence@ variants apply
-- only while the committee is in a state of no confidence, and @epoch_state.no_confidence_id@ is
-- documented upstream as \"TODO: This remains NULL\" — so that state cannot be read from the data
-- at all, and predicting ratification is cut anyway.
module Query.Thresholds
  ( thresholdColumnFor,
    paramGroupColumns,
    securityGroupColumns,
    spoParamChangeApplies,
    drepParamChangeThreshold,
    unmappedParamColumns,
  )
where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Types (GovActionType (..), VoterRole (..))

-- | The threshold column for a (role, action type), or 'Nothing' when none applies.
--
-- For @(SPO, ParameterChange)@ this names @pvtpp_security_group@, which is the column a
-- @pvt_%@ prefix scan silently misses — db-sync spells it without the @pvt_@ separator.
-- Naming the column is not the same as the column applying: 'spoParamChangeApplies' answers
-- whether it does for a particular proposal.
thresholdColumnFor :: VoterRole -> GovActionType -> Maybe Text
thresholdColumnFor = \case
  ConstitutionalCommittee -> const Nothing
  DRep -> \case
    NoConfidence -> Just "dvt_motion_no_confidence"
    NewCommittee -> Just "dvt_committee_normal"
    NewConstitution -> Just "dvt_update_to_constitution"
    HardForkInitiation -> Just "dvt_hard_fork_initiation"
    TreasuryWithdrawals -> Just "dvt_treasury_withdrawal"
    -- The maximum over the groups the proposal touches; see 'drepParamChangeThreshold'.
    ParameterChange -> Nothing
    -- An InfoAction is never ratifiable, so no threshold applies — and a participation metric
    -- must not treat a missing vote on one as a failure to reach quorum.
    InfoAction -> Nothing
  SPO -> \case
    NoConfidence -> Just "pvt_motion_no_confidence"
    NewCommittee -> Just "pvt_committee_normal"
    HardForkInitiation -> Just "pvt_hard_fork_initiation"
    ParameterChange -> Just "pvtpp_security_group"
    -- SPOs do not vote on either of these.
    NewConstitution -> Nothing
    TreasuryWithdrawals -> Nothing
    InfoAction -> Nothing

-- | Every @param_proposal@ column that is a protocol parameter, mapped to its CIP-1694 group's
-- DRep threshold column.
--
-- Enumerated against db-sync 13.7.1.0's @param_proposal@ and CIP-1694's parameter groups. The
-- grouping is the ledger's (@Cardano.Ledger.Conway.PParams.ppGroups@), not ours — a reader who
-- disagrees should argue with CIP-1694, which is why the mapping is a table rather than a rule.
--
-- @cost_model_id@ IS a parameter here, not bookkeeping: it is how db-sync stores @costModels@,
-- which CIP-1694 puts in the technical group. The columns left out are listed in
-- 'unmappedParamColumns' with a reason each, and a test asserts the two lists together cover
-- @param_proposal@ exactly — so a column added by a db-sync upgrade fails CI instead of silently
-- counting as no group at all.
paramGroupColumns :: [(Text, Text)]
paramGroupColumns =
  map (,"dvt_p_p_network_group") network
    <> map (,"dvt_p_p_economic_group") economic
    <> map (,"dvt_p_p_technical_group") technical
    <> map (,"dvt_p_p_gov_group") governance
  where
    network =
      [ "max_block_size",
        "max_tx_size",
        "max_bh_size",
        "max_val_size",
        "max_tx_ex_mem",
        "max_tx_ex_steps",
        "max_block_ex_mem",
        "max_block_ex_steps",
        "max_collateral_inputs"
      ]
    economic =
      [ "min_fee_a",
        "min_fee_b",
        "key_deposit",
        "pool_deposit",
        "monetary_expand_rate",
        "treasury_growth_rate",
        "min_pool_cost",
        "coins_per_utxo_size",
        "price_mem",
        "price_step",
        "min_fee_ref_script_cost_per_byte"
      ]
    technical =
      [ "influence",
        "max_epoch",
        "optimal_pool_count",
        "cost_model_id",
        "collateral_percent"
      ]
    governance =
      [ "pvt_motion_no_confidence",
        "pvt_committee_normal",
        "pvt_committee_no_confidence",
        "pvt_hard_fork_initiation",
        "pvtpp_security_group",
        "dvt_motion_no_confidence",
        "dvt_committee_normal",
        "dvt_committee_no_confidence",
        "dvt_update_to_constitution",
        "dvt_hard_fork_initiation",
        "dvt_p_p_network_group",
        "dvt_p_p_economic_group",
        "dvt_p_p_technical_group",
        "dvt_p_p_gov_group",
        "dvt_treasury_withdrawal",
        "committee_min_size",
        "committee_max_term_length",
        "gov_action_lifetime",
        "gov_action_deposit",
        "drep_deposit",
        "drep_activity"
      ]

-- | The @param_proposal@ columns that are deliberately NOT parameters, with the reason.
--
-- Published so the exhaustiveness test can be written against the real table: a column that is
-- in neither this list nor 'paramGroupColumns' is a column nobody classified, which would make
-- 'drepParamChangeThreshold' quietly return 'Nothing' for a proposal that touches it.
unmappedParamColumns :: [(Text, Text)]
unmappedParamColumns =
  [ ("id", "row key"),
    ("epoch_no", "row key"),
    ("key", "the proposing genesis key, Shelley-era bookkeeping"),
    ("registered_tx_id", "row key"),
    ("entropy", "Shelley extra entropy; removed from the protocol"),
    ("decentralisation", "Shelley d parameter; fixed at 0 since Vasil"),
    ("protocol_major", "set by a HardForkInitiation, never by a ParameterChange"),
    ("protocol_minor", "set by a HardForkInitiation, never by a ParameterChange"),
    ("min_utxo_value", "pre-Alonzo; superseded by coins_per_utxo_size")
  ]

-- | The CIP-1694 security group: the parameters whose change needs an SPO vote.
--
-- This list, not the threshold column, is what makes @pvtpp_security_group@ apply at all: a
-- ParameterChange that touches none of these is ratified by DReps alone, and counting an SPO's
-- silence on it as a missed vote would be wrong.
--
-- @maxBlockExecutionUnits@ is one CIP-1694 parameter and two db-sync columns, so both appear.
securityGroupColumns :: [Text]
securityGroupColumns =
  [ "max_block_size",
    "max_tx_size",
    "max_bh_size",
    "max_val_size",
    "max_block_ex_mem",
    "max_block_ex_steps",
    "min_fee_a",
    "min_fee_b",
    "coins_per_utxo_size",
    "gov_action_deposit",
    "min_fee_ref_script_cost_per_byte"
  ]

-- | Does the SPO security-group threshold apply to a proposal touching these columns?
spoParamChangeApplies :: [Text] -> Bool
spoParamChangeApplies = any (`elem` securityGroupColumns)

-- | The DRep threshold expression for a ParameterChange touching these columns.
--
-- The MAXIMUM over the groups touched, because a proposal that changes a network parameter and a
-- governance parameter must clear the higher bar; taking either one alone would publish a
-- threshold the ledger would not have accepted.
--
-- One group gives the bare column rather than a one-argument @greatest@, because the simpler
-- expression is the one a reader can look up in @palmares.thresholds@ directly. The group order
-- is fixed (network, economic, technical, governance) so the expression is deterministic and two
-- proposals touching the same groups produce the same string.
drepParamChangeThreshold :: [Text] -> Maybe Text
drepParamChangeThreshold touched = case groups of
  [] -> Nothing
  [g] -> Just g
  gs -> Just ("greatest(" <> T.intercalate ", " gs <> ")")
  where
    groups =
      nub
        [ g
          | g <-
              [ "dvt_p_p_network_group",
                "dvt_p_p_economic_group",
                "dvt_p_p_technical_group",
                "dvt_p_p_gov_group"
              ],
            any (\c -> lookup c paramGroupColumns == Just g) touched
        ]
