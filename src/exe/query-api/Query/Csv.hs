{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | CSV rendering for the governance DTOs.
--
-- __These are orphan instances, on purpose.__ @cassava@'s @ToNamedRecord@ lives in cassava, the
-- DTOs live in @offchain-lib@, and 'safeCell' — the formula-injection guard every text cell has
-- to pass through — lives in @webapi-lib@ beside the content type. The house layering keeps
-- @offchain-lib@ and @webapi-lib@ apart in both directions, so no library can see all three. The
-- alternatives were a second copy of the guard in @offchain-lib@, which is how a security control
-- drifts, or no CSV at all.
--
-- The orphan is contained: this module belongs to one executable, nothing else can define a
-- conflicting instance, and the instances are used only by this executable's routes.
module Query.Csv () where

import Data.Csv (DefaultOrdered (..), ToNamedRecord (..), header, namedRecord, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Numeric (showFFloat)
import Palmares.DomainTypes.Core.Types (ChainPoint (..), DRepId (..), GovActionId (..))
import Palmares.DomainTypes.Transfer.QueryResponses
  ( DRepSummary (..),
    DelegatorRow (..),
    GovActionLifecycle (..),
    GovActionSummary (..),
    VoteAnchor (..),
    VoteRecord (..),
  )
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.CSV (safeCell)

-- | An optional text cell, guarded. Empty rather than the string @"null"@: a spreadsheet shows an
-- empty cell as missing, which is what it is.
mtext :: Maybe Text -> Text
mtext = maybe "" safeCell

-- | An integer or an enum tag. Not guarded, and that is deliberate: prefixing an apostrophe to a
-- number turns the column into text and breaks the spreadsheet's own arithmetic, which is the
-- opposite of the point.
num :: (Show a) => a -> Text
num = T.pack . show

mnum :: (Show a) => Maybe a -> Text
mnum = maybe "" num

-- | A boolean, lowercase, so the CSV and the JSON say the same word for the same value.
-- Haskell's @show@ gives @True@; every spreadsheet and every CSV reader also accepts that, but a
-- consumer diffing the two formats should not have to know which is which.
bool :: Bool -> Text
bool b = if b then "true" else "false"

-- | A ratio in fixed notation.
--
-- Haskell's @show@ renders 0.099 as @9.900990099009901e-2@. Excel parses that; plenty of CSV
-- tooling does not, and a human reading the column certainly does not. Full precision is kept —
-- rounding here would make the CSV disagree with the JSON.
mrate :: Maybe Double -> Text
mrate = maybe "" (\x -> T.pack (showFFloat Nothing x ""))

-- | A timestamp, ISO-8601. Haskell's @show@ renders @2024-10-16 20:38:10 UTC@, which no
-- spreadsheet and no date parser reads as a date.
mtime :: Maybe UTCTime -> Text
mtime = maybe "" (T.pack . iso8601Show)

instance DefaultOrdered DRepSummary where
  headerOrder _ =
    header
      [ "id",
        "hex",
        "has_script",
        "status",
        "is_active",
        "active_until_epoch",
        "given_name",
        "language",
        "anchor_status",
        "registered_at",
        "age_days",
        "voting_power",
        "voting_power_epoch",
        "delegator_count",
        "eligible_actions",
        "votes_cast",
        "participation_rate",
        "rationale_rate",
        "open_actions_unvoted",
        "last_vote_at",
        "as_of_epoch"
      ]

-- | The CSV row.
--
-- @image_url@ is omitted deliberately: a column of URLs is noise in a spreadsheet and the field
-- most likely to be long. Everything a reader would compute with is here.
--
-- Enum cells go through 'jsonTag', not through @show@: the constructors carry a stripped prefix
-- (@DRepActive@ is @active@ on the wire), so a hand-rolled snake-caser would publish
-- @d_rep_active@ in the CSV and @active@ in the JSON for the same value.
instance ToNamedRecord DRepSummary where
  toNamedRecord s =
    namedRecord
      [ "id" .= safeCell (unDRepId (drepSummaryId s)),
        "hex" .= safeCell (drepSummaryHex s),
        "has_script" .= bool (drepSummaryHasScript s),
        "status" .= jsonTag (drepSummaryStatus s),
        "is_active" .= bool (drepSummaryIsActive s),
        "active_until_epoch" .= mnum (drepSummaryActiveUntilEpoch s),
        "given_name" .= mtext (drepSummaryGivenName s),
        "language" .= mtext (drepSummaryLanguage s),
        "anchor_status" .= maybe "" jsonTag (drepSummaryAnchorStatus s),
        "registered_at" .= mtime (drepSummaryRegisteredAt s),
        "age_days" .= mnum (drepSummaryAgeDays s),
        "voting_power" .= num (drepSummaryVotingPower s),
        "voting_power_epoch" .= mnum (drepSummaryVotingPowerEpoch s),
        "delegator_count" .= num (drepSummaryDelegatorCount s),
        "eligible_actions" .= num (drepSummaryEligibleActions s),
        "votes_cast" .= num (drepSummaryVotesCast s),
        "participation_rate" .= mrate (drepSummaryParticipationRate s),
        "rationale_rate" .= mrate (drepSummaryRationaleRate s),
        "open_actions_unvoted" .= num (drepSummaryOpenActionsUnvoted s),
        "last_vote_at" .= mtime (drepSummaryLastVoteAt s),
        "as_of_epoch" .= num (drepSummaryAsOfEpoch s)
      ]

instance DefaultOrdered DelegatorRow where
  headerOrder _ = header ["stake_address", "lovelace", "delegated_at", "epoch", "is_current"]

-- | A delegation row. @delegated_at@ is flattened to its timestamp and epoch: a CSV cell cannot
-- hold a nested chain point, and a column of JSON objects is useless in a spreadsheet.
instance ToNamedRecord DelegatorRow where
  toNamedRecord r =
    namedRecord
      [ "stake_address" .= safeCell (delegatorRowStakeAddress r),
        "lovelace" .= mnum (delegatorRowLovelace r),
        "delegated_at" .= T.pack (iso8601Show (chainPointTime (delegatorRowDelegatedAt r))),
        "epoch" .= num (chainPointEpoch (delegatorRowDelegatedAt r)),
        "is_current" .= bool (delegatorRowIsCurrent r)
      ]

instance DefaultOrdered GovActionSummary where
  headerOrder _ =
    header
      [ "id",
        "bech32",
        "type",
        "title",
        "state",
        "proposed_at",
        "proposed_epoch",
        "expires_epoch",
        "last_votable_epoch",
        "ratified_epoch",
        "enacted_epoch",
        "expired_epoch",
        "dropped_epoch",
        "deposit",
        "return_address",
        "treasury_amount",
        "votes_cast"
      ]

-- | A governance action row. The lifecycle object is flattened into its columns: all four epochs
-- travel, because the single-valued @state@ is a reading of them and a spreadsheet reader may
-- want to apply their own.
--
-- @abstract@ is omitted — it is prose, and a paragraph in a CSV cell is noise.
instance ToNamedRecord GovActionSummary where
  toNamedRecord g =
    namedRecord
      [ "id" .= safeCell (unGovActionId (govActionSummaryId g)),
        "bech32" .= safeCell (govActionSummaryBech32 g),
        "type" .= jsonTag (govActionSummaryType g),
        "title" .= mtext (govActionSummaryTitle g),
        "state" .= jsonTag (govActionLifecycleState lc),
        "proposed_at" .= T.pack (iso8601Show (chainPointTime (govActionSummaryProposedAt g))),
        "proposed_epoch" .= num (chainPointEpoch (govActionSummaryProposedAt g)),
        "expires_epoch" .= mnum (govActionSummaryExpiresEpoch g),
        "last_votable_epoch" .= mnum (govActionSummaryLastVotableEpoch g),
        "ratified_epoch" .= mnum (govActionLifecycleRatifiedEpoch lc),
        "enacted_epoch" .= mnum (govActionLifecycleEnactedEpoch lc),
        "expired_epoch" .= mnum (govActionLifecycleExpiredEpoch lc),
        "dropped_epoch" .= mnum (govActionLifecycleDroppedEpoch lc),
        "deposit" .= mnum (govActionSummaryDeposit g),
        "return_address" .= mtext (govActionSummaryReturnAddress g),
        "treasury_amount" .= mnum (govActionSummaryTreasuryAmount g),
        "votes_cast" .= num (govActionSummaryVotesCast g)
      ]
    where
      lc = govActionSummaryLifecycle g

instance DefaultOrdered VoteRecord where
  headerOrder _ =
    header
      [ "gov_action_id",
        "gov_action_bech32",
        "gov_action_type",
        "gov_action_title",
        "voter_role",
        "voter_id",
        "voter_hot_hash",
        "voter_name",
        "verdict",
        "cast_at",
        "epoch",
        "latency_hours",
        "is_final",
        "is_first",
        "revote_count",
        "anchor_url",
        "anchor_status",
        "voting_power",
        "voting_power_epoch"
      ]

-- | A vote row. The chain point and the anchor object are flattened into columns, because a cell
-- cannot hold a nested object and a column of JSON is useless in a spreadsheet.
--
-- Every row is present, including superseded ones: @is_final@ and @revote_count@ are what a reader
-- filters on. Dropping them here would make the CSV disagree with the JSON about what happened.
instance ToNamedRecord VoteRecord where
  toNamedRecord v =
    namedRecord
      [ "gov_action_id" .= safeCell (unGovActionId (voteRecordGovActionId v)),
        "gov_action_bech32" .= safeCell (voteRecordGovActionBech32 v),
        "gov_action_type" .= jsonTag (voteRecordGovActionType v),
        "gov_action_title" .= mtext (voteRecordGovActionTitle v),
        "voter_role" .= jsonTag (voteRecordVoterRole v),
        "voter_id" .= safeCell (voteRecordVoterId v),
        "voter_hot_hash" .= mtext (voteRecordVoterHotHash v),
        "voter_name" .= mtext (voteRecordVoterName v),
        "verdict" .= jsonTag (voteRecordVerdict v),
        "cast_at" .= T.pack (iso8601Show (chainPointTime (voteRecordCastAt v))),
        "epoch" .= num (chainPointEpoch (voteRecordCastAt v)),
        "latency_hours" .= mrate (voteRecordLatencyHours v),
        "is_final" .= bool (voteRecordIsFinal v),
        "is_first" .= bool (voteRecordIsFirst v),
        "revote_count" .= num (voteRecordRevoteCount v),
        "anchor_url" .= mtext (voteAnchorUrl =<< voteRecordAnchor v),
        "anchor_status" .= maybe "" (jsonTag . voteAnchorStatus) (voteRecordAnchor v),
        "voting_power" .= mnum (voteRecordVotingPower v),
        "voting_power_epoch" .= mnum (voteRecordVotingPowerEpoch v)
      ]
