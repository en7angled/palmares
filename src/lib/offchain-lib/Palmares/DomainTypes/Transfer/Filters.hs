{-# LANGUAGE OverloadedStrings #-}

-- | Query listing filter record types and query-param constructors (shared by query-api handlers).
module Palmares.DomainTypes.Transfer.Filters
  ( ProfileFilter (..),
    AttestationFilter (..),
    profileFilterFromParams,
    attestationFilterFromParams,
    DRepFilter (..),
    emptyDRepFilter,
    drepFilterFromParams,
    GovActionFilter (..),
    emptyGovActionFilter,
    VoteFilter (..),
    emptyVoteFilter,
    GovActivityFilter (..),
    emptyGovActivityFilter,
    DelegationFilter (..),
    emptyDelegationFilter,
    SPOFilter (..),
    emptySPOFilter,
    TreasuryWithdrawalFilter (..),
    emptyTreasuryWithdrawalFilter,
    AttestProfileFilter (..),
    emptyAttestProfileFilter,
    AttestationRecordFilter (..),
    emptyAttestationRecordFilter,
    DisputeFilter (..),
    emptyDisputeFilter,
  )
where

import Data.Text (Text)
import Data.Int (Int64)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types qualified as Core
import Palmares.DomainTypes.Core.Types
import GeniusYield.Types (GYTime)

optionalNonEmpty :: [a] -> Maybe [a]
optionalNonEmpty xs = if null xs then Nothing else Just xs

-- | Optional filters for the profiles listing endpoint.
data ProfileFilter = ProfileFilter
  { profileFilterId :: Maybe [ProfileRefAC], -- ^ Restrict to these profile IDs
    profileFilterType :: Maybe ProfileType, -- ^ One of the six profile kinds
    profileFilterName :: Maybe Text, -- ^ Exact or prefix name match
    profileFilterDescription :: Maybe Text, -- ^ Substring match on description
    profileFilterTextSearch :: Maybe Text, -- ^ Free-text search across name and description
    -- | Registered at or after this chain slot. A slot, not a timestamp: @created_at_slot@ is
    -- the only time a projection row carries (inherited fix #5), and comparing on it keeps the
    -- indexed column in play. Handlers translate a @since@ query param with
    -- 'Palmares.TxBuilding.Utils.utcToSlot'.
    profileFilterRegisteredAfterSlot :: Maybe Integer
  }

-- | Optional filters for the attestations listing endpoint.
data AttestationFilter = AttestationFilter
  { attestationFilterId :: Maybe [AttestationAC], -- ^ Restrict to these attestation asset classes
    attestationFilterSubjectProfileId :: Maybe [ProfileRefAC], -- ^ Recipient profile IDs
    attestationFilterIssuerProfileId :: Maybe [ProfileRefAC], -- ^ Issuer profile IDs
    attestationFilterIsAccepted :: Maybe Bool, -- ^ Acceptance status
    attestationFilterDateInterval :: (Maybe GYTime, Maybe GYTime), -- ^ Date range (from, to) inclusive
    attestationFilterTextSearch :: Maybe Text -- ^ Free-text search
  }

-- | Build profile filter from query params (single source of truth for list handlers).
profileFilterFromParams :: [ProfileRefAC] -> Maybe ProfileType -> Maybe Text -> ProfileFilter
profileFilterFromParams profileRefs profileType q =
  ProfileFilter
    { profileFilterId = optionalNonEmpty profileRefs,
      profileFilterType = profileType,
      profileFilterName = Nothing,
      profileFilterDescription = Nothing,
      profileFilterTextSearch = q,
      profileFilterRegisteredAfterSlot = Nothing
    }

-- | Build attestation filter from query params.
attestationFilterFromParams ::
  [AttestationAC] ->
  [ProfileRefAC] ->
  [ProfileRefAC] ->
  Maybe Bool ->
  Maybe GYTime ->
  Maybe GYTime ->
  Maybe Text ->
  AttestationFilter
attestationFilterFromParams attestationIds subjectRefs issuerRefs isAccepted fromTime toTime q =
  AttestationFilter
    { attestationFilterId = optionalNonEmpty attestationIds,
      attestationFilterSubjectProfileId = optionalNonEmpty subjectRefs,
      attestationFilterIssuerProfileId = optionalNonEmpty issuerRefs,
      attestationFilterIsAccepted = isAccepted,
      attestationFilterDateInterval = (fromTime, toTime),
      attestationFilterTextSearch = q
    }

-- ---------------------------------------------------------------------------------------------

-- * Governance filters

-- | Every filter @GET \/dreps@ accepts.
--
-- Repeatable parameters are a list, and an EMPTY list is no filter rather than \"match nothing\".
-- That reading is the one a client expects — asking for no particular status means asking for any
-- — and it is the one that makes a UI's \"clear filters\" button work without a special case.
--
-- Within a repeatable parameter the values are OR'd; across parameters they are AND'd.
data DRepFilter = DRepFilter
  { -- | Defaults to the two REGISTERED statuses when the client sends none. @\/dreps@ is a
    -- delegation-discovery list, and preprod's 511 retired DReps against its 294 registered ones
    -- would make the default page mostly useless. @?status=retired@ asks for them explicitly.
    drepFilterStatus :: [Core.DRepStatus],
    drepFilterAnchorStatus :: [Core.AnchorStatus],
    drepFilterHasScript :: Maybe Bool,
    -- | Lovelace. 'Int64' and not 'Integer' because the bound is bound into SQL and persistent
    -- has no @PersistField Integer@; the maximum ADA supply is about 4.5e16 lovelace, four
    -- hundred times inside an 'Int64'.
    drepFilterMinVotingPower :: Maybe Int64,
    drepFilterMaxVotingPower :: Maybe Int64,
    drepFilterMinDelegators :: Maybe Int,
    drepFilterMinParticipationRate :: Maybe Double,
    drepFilterMinRationaleRate :: Maybe Double,
    drepFilterRegisteredBefore :: Maybe UTCTime,
    drepFilterRegisteredAfter :: Maybe UTCTime,
    drepFilterMinAgeDays :: Maybe Int,
    -- | Voted, or did not vote, on this governance action. Both take the canonical
    -- @\<tx_hash_hex\>#\<index\>@ form.
    drepFilterVotedOn :: Maybe Core.GovActionId,
    drepFilterNotVotedOn :: Maybe Core.GovActionId,
    drepFilterLanguage :: Maybe Text,
    -- | Had voting power in this epoch. Reads @palmares.drep_epoch_power@, so it answers \"was
    -- this DRep counted then\" rather than \"is it counted now\".
    drepFilterActiveInEpoch :: Maybe Int,
    -- | Free text against the DRep's published name, through a trigram index.
    drepFilterQ :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: the default page.
emptyDRepFilter :: DRepFilter
emptyDRepFilter =
  DRepFilter
    { drepFilterStatus = [],
      drepFilterAnchorStatus = [],
      drepFilterHasScript = Nothing,
      drepFilterMinVotingPower = Nothing,
      drepFilterMaxVotingPower = Nothing,
      drepFilterMinDelegators = Nothing,
      drepFilterMinParticipationRate = Nothing,
      drepFilterMinRationaleRate = Nothing,
      drepFilterRegisteredBefore = Nothing,
      drepFilterRegisteredAfter = Nothing,
      drepFilterMinAgeDays = Nothing,
      drepFilterVotedOn = Nothing,
      drepFilterNotVotedOn = Nothing,
      drepFilterLanguage = Nothing,
      drepFilterActiveInEpoch = Nothing,
      drepFilterQ = Nothing
    }

-- | Every filter @GET \/gov-actions@ accepts. Same conventions as 'DRepFilter': an empty
-- repeatable list is no filter, and across parameters the clauses are AND'd.
--
-- There is no default state filter here, unlike @\/dreps@: an expired action is still part of the
-- record and a list that hid 103 of preprod's 131 proposals by default would be hiding the
-- history the registry exists to publish.
data GovActionFilter = GovActionFilter
  { govActionFilterTypes :: [Core.GovActionType],
    govActionFilterStates :: [Core.GovActionState],
    govActionFilterAnchorStatus :: [Core.AnchorStatus],
    govActionFilterProposedFrom :: Maybe UTCTime,
    govActionFilterProposedTo :: Maybe UTCTime,
    govActionFilterExpiresBeforeEpoch :: Maybe Int,
    govActionFilterExpiresAfterEpoch :: Maybe Int,
    govActionFilterProposerStakeAddress :: Maybe Text,
    govActionFilterMinTreasuryAmount :: Maybe Int64,
    govActionFilterMaxTreasuryAmount :: Maybe Int64,
    -- | Free text against the action's CIP-108 title and abstract. Measured: only 7 of preprod's
    -- 131 proposals have fetched metadata, so this filter is sparse by nature and not by bug.
    govActionFilterQ :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every proposal, newest first.
emptyGovActionFilter :: GovActionFilter
emptyGovActionFilter =
  GovActionFilter
    { govActionFilterTypes = [],
      govActionFilterStates = [],
      govActionFilterAnchorStatus = [],
      govActionFilterProposedFrom = Nothing,
      govActionFilterProposedTo = Nothing,
      govActionFilterExpiresBeforeEpoch = Nothing,
      govActionFilterExpiresAfterEpoch = Nothing,
      govActionFilterProposerStakeAddress = Nothing,
      govActionFilterMinTreasuryAmount = Nothing,
      govActionFilterMaxTreasuryAmount = Nothing,
      govActionFilterQ = Nothing
    }

-- | Every filter @GET \/votes@ accepts. One endpoint serves four screens — a DRep's record, an
-- action's votes, a committee member's votes, and the global feed — which is why the filters are
-- repeatable rather than there being four routes.
--
-- @has_rationale@ is deliberately NOT a parameter: it is @anchor_status=valid@, which says which
-- of the five anchor outcomes the caller means instead of collapsing them into a boolean that
-- would quietly count an unreachable IPFS document as "no rationale".
data VoteFilter = VoteFilter
  { voteFilterRoles :: [Core.VoterRole],
    -- | A DRep's @drep1y…@, a pool's @pool1…@ or a committee member's COLD @cc_cold1…@ (D-24).
    -- One parameter for all three roles.
    voteFilterVoterIds :: [Text],
    voteFilterGovActionIds :: [Core.GovActionId],
    voteFilterVerdicts :: [Core.Vote],
    voteFilterGovActionTypes :: [Core.GovActionType],
    voteFilterAnchorStatus :: [Core.AnchorStatus],
    voteFilterFrom :: Maybe UTCTime,
    voteFilterTo :: Maybe UTCTime,
    voteFilterFromEpoch :: Maybe Int,
    voteFilterToEpoch :: Maybe Int,
    voteFilterQ :: Maybe Text,
    -- | @is_final@: keep only each voter's LAST vote on each action, or only the superseded ones.
    -- The rows already publish the flag; without the filter a client looking for the standing
    -- verdicts had to page all 3.24 M rows to find the 931 that carry it.
    voteFilterIsFinal :: Maybe Bool
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every vote, newest first.
emptyVoteFilter :: VoteFilter
emptyVoteFilter =
  VoteFilter
    { voteFilterRoles = [],
      voteFilterVoterIds = [],
      voteFilterGovActionIds = [],
      voteFilterVerdicts = [],
      voteFilterGovActionTypes = [],
      voteFilterAnchorStatus = [],
      voteFilterFrom = Nothing,
      voteFilterTo = Nothing,
      voteFilterFromEpoch = Nothing,
      voteFilterToEpoch = Nothing,
      voteFilterQ = Nothing,
      voteFilterIsFinal = Nothing
    }

drepFilterFromParams ::
  [Core.DRepStatus] ->
  [Core.AnchorStatus] ->
  Maybe Bool ->
  Maybe Int64 ->
  Maybe Int64 ->
  Maybe Int ->
  Maybe Double ->
  Maybe Double ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe Int ->
  Maybe Core.GovActionId ->
  Maybe Core.GovActionId ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  DRepFilter
drepFilterFromParams
  status
  anchorStatus
  hasScript
  minPower
  maxPower
  minDelegators
  minPart
  minRat
  regBefore
  regAfter
  minAge
  votedOn
  notVotedOn
  lang
  activeEpoch
  q =
    DRepFilter
      { drepFilterStatus = status,
        drepFilterAnchorStatus = anchorStatus,
        drepFilterHasScript = hasScript,
        drepFilterMinVotingPower = minPower,
        drepFilterMaxVotingPower = maxPower,
        drepFilterMinDelegators = minDelegators,
        drepFilterMinParticipationRate = minPart,
        drepFilterMinRationaleRate = minRat,
        drepFilterRegisteredBefore = regBefore,
        drepFilterRegisteredAfter = regAfter,
        drepFilterMinAgeDays = minAge,
        drepFilterVotedOn = votedOn,
        drepFilterNotVotedOn = notVotedOn,
        drepFilterLanguage = lang,
        drepFilterActiveInEpoch = activeEpoch,
        drepFilterQ = q
      }

-- | Every filter @GET \/delegations@ accepts.
--
-- @delegationFilterIsCurrent@ is a 'Bool' and not a 'Maybe Bool', unlike
-- @\/drep\/{id}\/delegators@'s: there, @is_current=false@ drops the clause and WIDENS to the
-- history; here it is a two-way filter and @false@ returns only the 289 addresses whose stake
-- account closed. Two routes, one parameter name, two meanings — spelled differently in the type
-- so a reader of either handler can see which one they have. The default is 'True', which is what
-- makes the unfiltered page a snapshot rather than an archive.
--
-- The @drep_id@ parameter lands in TWO fields because a 'Core.DRepId' can be either a credential
-- or one of the two reserved ledger options, and those match different columns. Both empty is "any
-- target"; either non-empty contributes one OR-arm to a single clause, so sending a credential and
-- @drep_always_abstain@ together means "either".
data DelegationFilter = DelegationFilter
  { -- | 28-byte credential hashes, hex, resolved by the handler through 'Core.drepIdHex'.
    delegationFilterDrepHex :: [Text],
    -- | @always_abstain@ / @always_no_confidence@, matched against @vote_delegation.target_kind@.
    delegationFilterReservedTargets :: [Text],
    delegationFilterStakeAddresses :: [Text],
    delegationFilterIsCurrent :: Bool,
    delegationFilterFrom :: Maybe UTCTime,
    delegationFilterTo :: Maybe UTCTime,
    -- | Lovelace. 'Int64' and not 'Integer' because it is bound into SQL and persistent has no
    -- @PersistField Integer@.
    delegationFilterMinLovelace :: Maybe Int64
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every current delegation, newest first.
emptyDelegationFilter :: DelegationFilter
emptyDelegationFilter =
  DelegationFilter
    { delegationFilterDrepHex = [],
      delegationFilterReservedTargets = [],
      delegationFilterStakeAddresses = [],
      delegationFilterIsCurrent = True,
      delegationFilterFrom = Nothing,
      delegationFilterTo = Nothing,
      delegationFilterMinLovelace = Nothing
    }

-- | Every filter @GET \/spos@ accepts.
--
-- There is no @q@, and that is a cut rather than an omission (C-10): an SPO row is a direct
-- @pool_stat@ \/ @pool_hash@ read, @ticker@ is null throughout F1 because
-- @off_chain_pool_data@ has 0 rows, and there is therefore no text column to match. An exact id
-- lookup is what @\/search@ is for.
data SPOFilter = SPOFilter
  { spoFilterMinVotingPower :: Maybe Int64,
    spoFilterMinVotesCast :: Maybe Int,
    -- | Had voting power in this epoch. Reads @pool_stat@ at that epoch, so it answers "was this
    -- pool counted then" rather than "is it counted now".
    spoFilterActiveInEpoch :: Maybe Int
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: the whole current distribution, most powerful first.
emptySPOFilter :: SPOFilter
emptySPOFilter =
  SPOFilter
    { spoFilterMinVotingPower = Nothing,
      spoFilterMinVotesCast = Nothing,
      spoFilterActiveInEpoch = Nothing
    }

-- | Every filter @GET \/treasury-withdrawals@ accepts. Same conventions as the others: an empty
-- repeatable list is no filter, and across parameters the clauses are AND'd.
data TreasuryWithdrawalFilter = TreasuryWithdrawalFilter
  { withdrawalFilterGovActionIds :: [Core.GovActionId],
    -- | Stake addresses, bech32, as the response publishes them.
    withdrawalFilterBeneficiaries :: [Text],
    withdrawalFilterEnactedFromEpoch :: Maybe Int,
    withdrawalFilterEnactedToEpoch :: Maybe Int,
    withdrawalFilterMinAmount :: Maybe Int64,
    withdrawalFilterMaxAmount :: Maybe Int64
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: all 83 preprod withdrawals.
emptyTreasuryWithdrawalFilter :: TreasuryWithdrawalFilter
emptyTreasuryWithdrawalFilter =
  TreasuryWithdrawalFilter
    { withdrawalFilterGovActionIds = [],
      withdrawalFilterBeneficiaries = [],
      withdrawalFilterEnactedFromEpoch = Nothing,
      withdrawalFilterEnactedToEpoch = Nothing,
      withdrawalFilterMinAmount = Nothing,
      withdrawalFilterMaxAmount = Nothing
    }

-- | Every filter @GET \/activity@ accepts. Same conventions as the other governance filters: an
-- empty repeatable list is no filter rather than "match nothing", values OR within a parameter and
-- AND across parameters.
--
-- No time or epoch range, and no @order_by@: position in this feed is the CURSOR. A @from@/@to@
-- pair would be a second way to say the same thing, and the two would disagree at the boundary
-- slot - which is the one place a feed must not disagree with itself.
data GovActivityFilter = GovActivityFilter
  { govActivityFilterEventTypes :: [Core.ActivityEventType],
    govActivityFilterSources :: [Core.ActivitySource],
    -- | Matched against @actor_id@ AS GIVEN, and additionally against its hex credential form when
    -- the value decodes as one (@drep1y...@, @cc_cold1...@, @pool1...@). The column holds a hex
    -- credential for the DRep and committee arms and a bech32 stake address for the delegation and
    -- proposal arms, so neither "always decode" nor "never decode" serves the whole feed, and a 400
    -- on a value that does not decode would reject every stake address.
    govActivityFilterActors :: [Text]
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: the whole feed, newest first.
emptyGovActivityFilter :: GovActivityFilter
emptyGovActivityFilter = GovActivityFilter [] [] []

-- ---------------------------------------------------------------------------------------------

-- * Attestation filters (the @palmares_attest@ projections)

--
-- Three NEW records rather than the inherited 'ProfileFilter' \/ 'AttestationFilter' above: those
-- two are shaped for the Belt System's esqueleto handlers (@Maybe [a]@ for \"no filter\", a
-- single-valued type, two unused name\/description fields) and are still referenced by the
-- comment-prefixed @Query.Projected@. These follow the governance convention instead — a plain
-- list, where EMPTY means no filter rather than \"match nothing\", values OR within a parameter
-- and AND across parameters — so the attestation handlers read like the governance ones.

-- | Every filter @GET \/profiles@ and @GET \/profiles\/by-credential\/{credential}@ accept.
data AttestProfileFilter = AttestProfileFilter
  { attestProfileFilterKinds :: [Core.ProfileType],
    -- | Whether the profile claims a governance credential at all: @profile_credential IS NOT
    -- NULL@. Separate from 'attestProfileFilterCredential' because \"claims something\" and
    -- \"claims this\" are different questions, and the first one is what a list facet asks.
    attestProfileFilterClaimed :: Maybe Bool,
    -- | One credential, as the CANONICAL CIP-129 string the projection stores. The handler
    -- produces it with 'Query.Attest.canonicalGovCredential' and never from request text
    -- directly, so a non-canonical bech32 spelling of the same credential still matches.
    attestProfileFilterCredential :: Maybe Text,
    -- | Free text against the profile's name and description.
    attestProfileFilterQ :: Maybe Text
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every profile.
emptyAttestProfileFilter :: AttestProfileFilter
emptyAttestProfileFilter =
  AttestProfileFilter
    { attestProfileFilterKinds = [],
      attestProfileFilterClaimed = Nothing,
      attestProfileFilterCredential = Nothing,
      attestProfileFilterQ = Nothing
    }

-- | Every filter @GET \/attestations@ and @GET \/profiles\/{id}\/attestations@ accept.
--
-- @subject@ and @issuer@ are single-valued where @kind@ is repeatable, which is what the two
-- questions are: a track record is about ONE subject, while \"which kinds\" is a facet.
-- @\/profiles\/{id}\/attestations@ is this filter with @subject@ pinned to the captured id, so the
-- track record and the global list are one query and cannot disagree.
--
-- The date bounds are 'UTCTime' and not @GYTime@, like every governance range in this module:
-- @attestation_date@ is a @timestamptz@ column, both types bind to it as the same
-- @PersistUTCTime@, and keeping it 'UTCTime' is what lets query-api declare the parameter without
-- depending on Atlas.
data AttestationRecordFilter = AttestationRecordFilter
  { attestationRecordFilterSubject :: Maybe Core.ProfileRefAC,
    attestationRecordFilterIssuer :: Maybe Core.ProfileRefAC,
    attestationRecordFilterKinds :: [Core.AttestationType],
    attestationRecordFilterAccepted :: Maybe Bool,
    attestationRecordFilterDateFrom :: Maybe UTCTime,
    attestationRecordFilterDateTo :: Maybe UTCTime
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every attestation.
emptyAttestationRecordFilter :: AttestationRecordFilter
emptyAttestationRecordFilter =
  AttestationRecordFilter
    { attestationRecordFilterSubject = Nothing,
      attestationRecordFilterIssuer = Nothing,
      attestationRecordFilterKinds = [],
      attestationRecordFilterAccepted = Nothing,
      attestationRecordFilterDateFrom = Nothing,
      attestationRecordFilterDateTo = Nothing
    }

-- | Every filter @GET \/disputes@ accepts.
--
-- @resolved@ is @verdict IS NOT NULL@ and not a verdict filter: a dispute's verdict is NULL while
-- it is open, so \"is it decided\" is a question about presence. Asking for a particular verdict
-- is a @kind@-style facet that F1 has no screen for.
data DisputeFilter = DisputeFilter
  { disputeFilterTarget :: Maybe Core.AttestationAC,
    disputeFilterResolved :: Maybe Bool
  }
  deriving stock (Show, Eq)

-- | The filter with nothing set: every dispute, newest first.
emptyDisputeFilter :: DisputeFilter
emptyDisputeFilter = DisputeFilter Nothing Nothing
