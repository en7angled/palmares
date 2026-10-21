{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Koios preprod wire types, for F1 check 6 (parity).
--
-- __Koios is a CHECK, never a source.__ Nothing in the serving path reads this module: it exists
-- so that a second, independently built index of the same chain can be compared against ours, and
-- so a disagreement is a finding rather than a surprise. Every number this API publishes comes
-- from our own views over cardano-db-sync.
--
-- The types here are the WIRE, not a domain model. They carry Koios's field names, Koios's
-- spellings and Koios's encodings, and the mapping into our own vocabulary is the handful of
-- @koios*@ functions at the bottom. Keeping the two apart is what makes a Koios change show up as
-- one failing decoder rather than as a silently different number somewhere downstream.
--
-- __Three things about the wire are load-bearing and were measured off the recordings in__
-- @test\/fixtures\/koios\/@:
--
--   1. __Lovelace arrives as a STRING.__ @deposit@, @amount@ and the withdrawal amounts are
--      @\"500000000\"@, not @500000000@. 'KoiosLovelace' accepts either, because a JSON number is
--      what a reader expects and Koios has published both shapes for different fields.
--   2. __@withdrawal@ is an ARRAY, empty when there is none.__ Not @null@ — every proposal row
--      carries @\"withdrawal\": []@ and only a @TreasuryWithdrawals@ action fills it.
--   3. __A committee vote is published under the HOT id.__ @proposal_votes.voter_id@ is
--      @cc_hot1…@, while we publish the COLD credential (D-24), because the cold key is the
--      identity that survives a rotation. The two cannot be compared as strings; the reconciler
--      resolves one to the other. This is the single biggest trap in comparing vote sets.
--
-- Refresh the fixtures with the commands in @test\/fixtures\/koios\/README.md@.
module Palmares.Reconcile.Koios
  ( -- * Wire encodings
    KoiosLovelace (..),

    -- * The eight endpoints
    KoiosTip (..),
    KoiosDRepListRow (..),
    KoiosDRepInfo (..),
    KoiosPowerRow (..),
    KoiosProposal (..),
    KoiosWithdrawal (..),
    KoiosVoteRow (..),
    KoiosDRepVoteRow (..),
    KoiosCommittee (..),
    KoiosCommitteeMember (..),

    -- * Into our own vocabulary
    koiosActionType,
    koiosDRepStatus,
    koiosVote,
    koiosVoterRole,
  )
where

import Data.Aeson (FromJSON (parseJSON), Value (Number, String), withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, typeMismatch)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TRead
import GHC.Generics (Generic)
import Palmares.DomainTypes.Core.Types (DRepStatus (..), GovActionType (..), Vote (..), VoterRole (..))

-- ---------------------------------------------------------------------------------------------

-- * Wire encodings

-- | A lovelace amount as Koios sends it: a decimal STRING, or sometimes a number.
--
-- Both are accepted deliberately. @deposit@ and @amount@ arrive quoted — measured,
-- @\"500000000\"@ and @\"3923709956713\"@ — which is the sane choice for a value that exceeds
-- IEEE-754's exact integer range, and it is why a naive @Int64@ field fails to decode. A bare
-- number is accepted too because other Koios fields use it and a reader should not have to know
-- which is which.
--
-- A fractional number is REFUSED rather than truncated: lovelace is an integer, and rounding one
-- silently is how a parity check comes back green on a number that is wrong.
newtype KoiosLovelace = KoiosLovelace {unKoiosLovelace :: Int64}
  deriving stock (Show, Eq, Ord)

instance FromJSON KoiosLovelace where
  parseJSON v = case v of
    String t -> case TRead.signed TRead.decimal t of
      Right (n, rest) | T.null rest -> pure (KoiosLovelace n)
      _ -> fail ("Palmares.Reconcile.Koios: not a decimal lovelace string: " <> show t)
    -- Delegated to Int64's own instance rather than inspected with Data.Scientific: it already
    -- refuses a fractional number, and refusing is the point — lovelace is an integer and
    -- rounding one silently is how a parity check comes back green on a number that is wrong.
    Number _ -> KoiosLovelace <$> parseJSON v
    _ -> typeMismatch "KoiosLovelace (string or integer)" v

-- ---------------------------------------------------------------------------------------------

-- * The eight endpoints

-- | @GET \/tip@. The point Koios is answering from.
--
-- Read FIRST by every reconciliation and compared against our own, because two indexes at
-- different tips disagree about everything that moved between them — and that disagreement is not
-- a defect in either. @block_time@ is a POSIX second, not an ISO-8601 string.
data KoiosTip = KoiosTip
  { koiosTipHash :: Text,
    koiosTipEpochNo :: Int,
    koiosTipAbsSlot :: Int64,
    koiosTipBlockNo :: Int64,
    koiosTipBlockTime :: Int64
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosTip where
  parseJSON = withObject "KoiosTip" $ \o ->
    KoiosTip
      <$> o .: "hash"
      <*> o .: "epoch_no"
      <*> o .: "abs_slot"
      <*> o .: "block_no"
      <*> o .: "block_time"

-- | One row of @GET \/drep_list@: the registry's membership, and nothing else.
--
-- @registered@ is carried although the recording filters on @registered=eq.true@: the parameter is
-- the caller's choice, and a decoder that assumed it would make the unfiltered call silently
-- wrong.
data KoiosDRepListRow = KoiosDRepListRow
  { koiosDRepListId :: Text,
    koiosDRepListHex :: Text,
    koiosDRepListHasScript :: Bool,
    koiosDRepListRegistered :: Bool
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosDRepListRow where
  parseJSON = withObject "KoiosDRepListRow" $ \o ->
    KoiosDRepListRow
      <$> o .: "drep_id"
      <*> o .: "hex"
      <*> o .: "has_script"
      <*> o .: "registered"

-- | One row of @POST \/drep_info@: the profile numbers for named credentials.
--
-- @drep_status@ and @active@ are SEPARATE facts and both are needed: Koios says @registered@ for a
-- DRep whose registration has lapsed and marks it @active: false@, where our own vocabulary has
-- two different statuses for those. 'koiosDRepStatus' is the mapping and takes both.
--
-- @live_delegator_count@ is a LIVE count, not an epoch snapshot, and it is the field that found
-- the deregistration bug in @palmares.live_delegation@: 13 against our 12, which was one stake
-- account that closed and reopened inside one epoch.
data KoiosDRepInfo = KoiosDRepInfo
  { koiosDRepInfoId :: Text,
    koiosDRepInfoHex :: Text,
    koiosDRepInfoHasScript :: Bool,
    koiosDRepInfoStatus :: Text,
    koiosDRepInfoActive :: Bool,
    koiosDRepInfoDeposit :: Maybe KoiosLovelace,
    koiosDRepInfoExpiresEpochNo :: Maybe Int,
    koiosDRepInfoAmount :: Maybe KoiosLovelace,
    koiosDRepInfoMetaUrl :: Maybe Text,
    koiosDRepInfoMetaHash :: Maybe Text,
    koiosDRepInfoLiveDelegatorCount :: Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosDRepInfo where
  parseJSON = withObject "KoiosDRepInfo" $ \o ->
    KoiosDRepInfo
      <$> o .: "drep_id"
      <*> o .: "hex"
      <*> o .: "has_script"
      <*> o .: "drep_status"
      <*> o .: "active"
      <*> o .:? "deposit"
      <*> o .:? "expires_epoch_no"
      <*> o .:? "amount"
      <*> o .:? "meta_url"
      <*> o .:? "meta_hash"
      <*> o .: "live_delegator_count"

-- | One row of @GET \/drep_voting_power_history@: a DRep's stake in one epoch.
--
-- The reserved ledger options appear here under their own @drep_id@ values exactly like real
-- DReps, which is the same shape @palmares.drep_epoch_power@ publishes (D-20). A comparison that
-- filtered them out of one side and not the other would be off by about half the total power.
data KoiosPowerRow = KoiosPowerRow
  { koiosPowerDRepId :: Text,
    koiosPowerEpochNo :: Int,
    koiosPowerAmount :: KoiosLovelace
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosPowerRow where
  parseJSON = withObject "KoiosPowerRow" $ \o ->
    KoiosPowerRow
      <$> o .: "drep_id"
      <*> o .: "epoch_no"
      <*> o .: "amount"

-- | One beneficiary of a @TreasuryWithdrawals@ action, inside 'KoiosProposal'.
data KoiosWithdrawal = KoiosWithdrawal
  { koiosWithdrawalStakeAddress :: Text,
    koiosWithdrawalAmount :: KoiosLovelace
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosWithdrawal where
  parseJSON = withObject "KoiosWithdrawal" $ \o ->
    KoiosWithdrawal
      <$> o .: "stake_address"
      <*> o .: "amount"

-- | One row of @GET \/proposal_list@: a governance action and its whole lifecycle.
--
-- The four lifecycle epochs are each @Maybe@ and they are the parity surface that matters most:
-- our own @palmares.gov_action@ derives a single @state@ from them, and a mismatch in any one of
-- them means the two indexes disagree about what the ledger did. Measured off the recording: 103
-- actions have @expired_epoch@ and 11 have none of the four set at all, which is exactly what we
-- publish.
--
-- @expiration@ is NOT one of them. It is the epoch the action's voting window closes in, set when
-- the action is proposed, and it is present on every row including the settled ones.
--
-- @withdrawal@ is an array and is @[]@ on every non-withdrawal action; @meta_json@ is deliberately
-- NOT decoded — it is the proposal's whole off-chain document, 3.74 MB of the recording's 3.9 MB,
-- and nothing in a parity check reads it.
data KoiosProposal = KoiosProposal
  { koiosProposalId :: Text,
    koiosProposalTxHash :: Text,
    koiosProposalIndex :: Int,
    koiosProposalType :: Text,
    koiosProposalDeposit :: Maybe KoiosLovelace,
    koiosProposalReturnAddress :: Maybe Text,
    koiosProposalProposedEpoch :: Maybe Int,
    koiosProposalRatifiedEpoch :: Maybe Int,
    koiosProposalEnactedEpoch :: Maybe Int,
    koiosProposalDroppedEpoch :: Maybe Int,
    koiosProposalExpiredEpoch :: Maybe Int,
    koiosProposalExpiration :: Maybe Int,
    koiosProposalMetaUrl :: Maybe Text,
    koiosProposalMetaHash :: Maybe Text,
    koiosProposalMetaIsValid :: Maybe Bool,
    koiosProposalWithdrawals :: [KoiosWithdrawal]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosProposal where
  parseJSON = withObject "KoiosProposal" $ \o ->
    KoiosProposal
      <$> o .: "proposal_id"
      <*> o .: "proposal_tx_hash"
      <*> o .: "proposal_index"
      <*> o .: "proposal_type"
      <*> o .:? "deposit"
      <*> o .:? "return_address"
      <*> o .:? "proposed_epoch"
      <*> o .:? "ratified_epoch"
      <*> o .:? "enacted_epoch"
      <*> o .:? "dropped_epoch"
      <*> o .:? "expired_epoch"
      <*> o .:? "expiration"
      <*> o .:? "meta_url"
      <*> o .:? "meta_hash"
      <*> o .:? "meta_is_valid"
      -- `withdrawal`, singular, holding a list. Absent is the same as empty here: a proposal that
      -- is not a withdrawal has no beneficiaries either way.
      <*> (maybe [] id <$> o .:? "withdrawal")

-- | One row of @GET \/proposal_votes@: a vote on one action, across all three roles.
--
-- __@voter_id@ is the HOT id for a committee vote__ (@cc_hot1…@), while we publish the cold
-- credential. @voter_hex@ is that same hot key in hex. Comparing these to our @voter_id@ as
-- strings finds nothing; the cold credential in force at the vote's transaction is what the two
-- have in common.
--
-- Koios returns the LATEST vote per voter here, so a re-voted action yields one row per voter
-- where our @\/votes@ returns every row and marks one @is_final@. The recording pins an action
-- with a re-vote for exactly this reason.
data KoiosVoteRow = KoiosVoteRow
  { koiosVoteRole :: Text,
    koiosVoteVoterId :: Text,
    koiosVoteVoterHex :: Text,
    koiosVoteVoterHasScript :: Bool,
    koiosVoteVote :: Text,
    koiosVoteBlockTime :: Int64,
    koiosVoteMetaUrl :: Maybe Text,
    koiosVoteMetaHash :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosVoteRow where
  parseJSON = withObject "KoiosVoteRow" $ \o ->
    KoiosVoteRow
      <$> o .: "voter_role"
      <*> o .: "voter_id"
      <*> o .: "voter_hex"
      <*> o .: "voter_has_script"
      <*> o .: "vote"
      <*> o .: "block_time"
      <*> o .:? "meta_url"
      <*> o .:? "meta_hash"

-- | One row of @GET \/drep_votes@: one DRep's record, action by action.
--
-- A different shape from 'KoiosVoteRow' and not a special case of it: this one names the ACTION
-- and omits the voter, because the voter is the request. It carries @vote_tx_hash@, which is what
-- lets a disagreement be chased to one transaction instead of to a count.
data KoiosDRepVoteRow = KoiosDRepVoteRow
  { koiosDRepVoteProposalId :: Text,
    koiosDRepVoteProposalTxHash :: Text,
    koiosDRepVoteProposalIndex :: Int,
    koiosDRepVoteTxHash :: Text,
    koiosDRepVoteBlockTime :: Int64,
    koiosDRepVoteVote :: Text,
    koiosDRepVoteMetaUrl :: Maybe Text,
    koiosDRepVoteMetaHash :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosDRepVoteRow where
  parseJSON = withObject "KoiosDRepVoteRow" $ \o ->
    KoiosDRepVoteRow
      <$> o .: "proposal_id"
      <*> o .: "proposal_tx_hash"
      <*> o .: "proposal_index"
      <*> o .: "vote_tx_hash"
      <*> o .: "block_time"
      <*> o .: "vote"
      <*> o .:? "meta_url"
      <*> o .:? "meta_hash"

-- | One member inside 'KoiosCommittee'.
--
-- BOTH credentials and BOTH script flags travel, which is the whole reason this is comparable:
-- the published CIP-129 id's header byte says key-or-script and has to come from the same
-- credential as the hash it decorates. Measured off the recording: all three preprod members are
-- scripts on both keys.
--
-- @status@ is Koios's own vocabulary, not ours. Of its values only @authorized@ occurs on preprod,
-- for all three members; 'koiosDRepStatus' has no counterpart here because a committee member's
-- standing is a different enum — our own publishes @active@ for the same three.
data KoiosCommitteeMember = KoiosCommitteeMember
  { koiosMemberStatus :: Text,
    koiosMemberHotId :: Maybe Text,
    koiosMemberColdId :: Text,
    koiosMemberHotHex :: Maybe Text,
    koiosMemberColdHex :: Text,
    koiosMemberHotHasScript :: Maybe Bool,
    koiosMemberColdHasScript :: Bool,
    koiosMemberExpirationEpoch :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosCommitteeMember where
  parseJSON = withObject "KoiosCommitteeMember" $ \o ->
    KoiosCommitteeMember
      <$> o .: "status"
      -- The hot key is absent for a member who has never authorized one, which is a real state and
      -- not a gap in the data.
      <*> o .:? "cc_hot_id"
      <*> o .: "cc_cold_id"
      <*> o .:? "cc_hot_hex"
      <*> o .: "cc_cold_hex"
      <*> o .:? "cc_hot_has_script"
      <*> o .: "cc_cold_has_script"
      <*> o .:? "expiration_epoch"

-- | @GET \/committee_info@, one element of it.
--
-- The endpoint returns an ARRAY of committees, not a single object — the plan's own jq for this
-- read @.members[].status@ and errored out on it. The array is the committee's history, newest
-- first; preprod has one element, quorum 2\/3, three members.
data KoiosCommittee = KoiosCommittee
  { koiosCommitteeProposalId :: Maybe Text,
    koiosCommitteeProposalTxHash :: Maybe Text,
    koiosCommitteeProposalIndex :: Maybe Int,
    koiosCommitteeQuorumNumerator :: Int,
    koiosCommitteeQuorumDenominator :: Int,
    koiosCommitteeMembers :: [KoiosCommitteeMember]
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON KoiosCommittee where
  parseJSON = withObject "KoiosCommittee" $ \o ->
    KoiosCommittee
      <$> o .:? "proposal_id"
      <*> o .:? "proposal_tx_hash"
      <*> o .:? "proposal_index"
      <*> o .: "quorum_numerator"
      <*> o .: "quorum_denominator"
      <*> (maybe [] id <$> o .:? "members")

-- ---------------------------------------------------------------------------------------------

-- * Into our own vocabulary

-- | Koios's @proposal_type@ to ours.
--
-- The seven spellings happen to equal our constructor names, and this is still written out rather
-- than derived from them. Two reasons: a Koios rename must fail HERE, in one function with a test
-- behind it, rather than become a @Nothing@ that a reconciler reads as "no such action"; and the
-- equality is a coincidence of two independent choices, not a contract either side owes the other.
--
-- All seven occur in the recording, so none of these lines is speculative.
koiosActionType :: Text -> Maybe GovActionType
koiosActionType = \case
  "ParameterChange" -> Just ParameterChange
  "HardForkInitiation" -> Just HardForkInitiation
  "TreasuryWithdrawals" -> Just TreasuryWithdrawals
  "NoConfidence" -> Just NoConfidence
  "NewCommittee" -> Just NewCommittee
  "NewConstitution" -> Just NewConstitution
  "InfoAction" -> Just InfoAction
  _ -> Nothing

-- | Koios's @(drep_status, active)@ pair to our 'DRepStatus'.
--
-- TWO inputs, because Koios splits what we join: it says @registered@ for a DRep whose
-- registration has lapsed and marks the lapse in @active@, where we publish @inactive@ for
-- exactly that state. Taking @drep_status@ alone would report every lapsed DRep as active.
--
-- 'DRepReserved' has no Koios counterpart: the two reserved ledger options are not DReps and do
-- not appear in @drep_list@ or @drep_info@ at all. They appear only in the power history, under
-- their own ids, which is why 'KoiosPowerRow' carries no status.
--
-- __'DRepUnknown' has no Koios counterpart either, and that asymmetry is correct rather than a gap
-- to close here.__ Koios computes the activity deadline itself, so it always has an answer and never
-- reports "unknown"; we publish @unknown@ precisely where db-sync gave us no deadline. This function
-- maps what KOIOS said, and widening it to absorb our own uncertainty would be putting words in the
-- reference's mouth — the one thing a parity check must not do. The resulting difference is a real,
-- reported divergence, waived with its measurements in @config\/reconcile-exceptions.yaml@ under R2.
--
-- Only @registered@ was observed on preprod. The other two lines are Koios's documented values and
-- are the reason this returns a 'Maybe': an unknown status is a finding, not a default.
koiosDRepStatus :: Text -> Bool -> Maybe DRepStatus
koiosDRepStatus status isActive = case status of
  "registered" -> Just (if isActive then DRepActive else DRepInactive)
  "retired" -> Just DRepRetired
  "not_registered" -> Just DRepRetired
  _ -> Nothing

-- | Koios's @vote@ to ours.
koiosVote :: Text -> Maybe Vote
koiosVote = \case
  "Yes" -> Just Yes
  "No" -> Just No
  "Abstain" -> Just Abstain
  _ -> Nothing

-- | Koios's @voter_role@ to ours.
--
-- @SPO@, not @StakePool@: the three spellings are Koios's and they match db-sync's enum rather
-- than our wire form, which is @spo@. One more reason the mapping is explicit.
koiosVoterRole :: Text -> Maybe VoterRole
koiosVoterRole = \case
  "DRep" -> Just DRep
  "SPO" -> Just SPO
  "ConstitutionalCommittee" -> Just ConstitutionalCommittee
  _ -> Nothing
