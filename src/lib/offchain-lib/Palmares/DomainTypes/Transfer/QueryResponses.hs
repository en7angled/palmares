{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Wire response types for the query API that include @thumbnail_uri@. Domain
-- types in offchain-lib store image URIs only; this module maps to JSON and
-- derives thumbnails via a query-local helper (today @image_uri@; may later
-- resolve cached or CDN URLs).
--
-- JSON uses @StripPrefix@ + @CamelToSnake@ (see 'ProfileResponse', 'LineageGraphData').
--
-- __The page envelope and the error body are NOT re-exported here__, although every DTO is
-- wrapped in one. @Page@, @Cursor@, @ApiError@, @ErrorCode@ and @errorCodeToHttpStatus@ live in
-- @Palmares.WebAPI.Envelope@, and re-exporting them would mean @offchain-lib@ depending on
-- @webapi-lib@ — an OUTWARD dependency, which the house layering forbids in both directions
-- (@webapi-lib@ keeps no project-library dependency at all). Consumers import that module
-- directly; every executable already depends on both libraries, so the cost is one import line,
-- which is the right price for keeping the layering real.
module Palmares.DomainTypes.Transfer.QueryResponses
  ( ProfileResponse (..),
    AchievementResponse (..),
    OrganizationProfileResponse (..),
    profileToResponse,
    achievementToResponse,
    organizationProfileToResponse,
    SearchResults (..),
    SearchGroup (..),
    SearchHit (..),
    SearchTarget (..),
    LineageGraphData (..),
    LineageNode (..),
    LineageEdge (..),
    AchievementInformationResponse (..),
    achievementInformationToResponse,
    AchievementsMonthlyStatsResponse (..),
    AchievementsPageResponse (..),
    ProfilesPageResponse (..),
    OrganizationExplorerPageResponse (..),
    TopOrganizationResponse (..),
    topOrganizationResponse,
    ActivityEventDetails (..),
    ActivityEventResponse (..),
    SyncStatus (..),
    EpochParamsSummary (..),
    StatusResponse (..),
    DRepSummary (..),
    VoteCounts (..),
    TypeBreakdown (..),
    DRepMetrics (..),
    EpochPowerPoint (..),
    DelegatorStats (..),
    DelegatorRow (..),
    DRepUpdateRow (..),
    AnchorReference (..),
    AnchorContent (..),
    DRepDetailResponse (..),
    GovActionLifecycle (..),
    GovActionSummary (..),
    VoteTally (..),
    ChainPointEpochOnly (..),
    TreasuryWithdrawalRow (..),
    ParamChangeRow (..),
    ProposerSummary (..),
    GovActionAnchorContent (..),
    GovActionDetailResponse (..),
    VoteAnchor (..),
    VoteRecord (..),
  )
where

import Data.Aeson (FromJSON (parseJSON), withObject, (.!=), (.:), (.:?))
import Data.Swagger (ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Internal.Schema ()
import Data.Text (Text)
import Data.Time (UTCTime)
import Deriving.Aeson
import Palmares.DomainTypes.Core.Types qualified as Core
import Palmares.DomainTypes.Transfer.OrderBy (ActivityEventType (..))
import Palmares.DomainTypes.Transfer.Types qualified as T
import GeniusYield.Types (GYTime)
import Palmares.Utils (mkStripPrefixSchemaOptions)

-- * Profile

data ProfileResponse = ProfileResponse
  { profileId :: Core.ProfileRefAC,
    profileName :: Text,
    profileDescription :: Text,
    profileImageURI :: Text,
    profileThumbnailURI :: Text,
    profileType :: Core.ProfileType
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profile", CamelToSnake]] ProfileResponse

instance ToSchema ProfileResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "profile")

profileToResponse :: Core.Profile -> ProfileResponse
profileToResponse p =
  ProfileResponse
    { profileId = Core.profileId p,
      profileName = Core.profileName p,
      profileDescription = Core.profileDescription p,
      profileImageURI = Core.profileImageURI p,
      profileThumbnailURI = deriveThumbnailUri (Core.profileImageURI p),
      profileType = Core.profileType p
    }

-- * Achievement

data AchievementResponse = AchievementResponse
  { achievementId :: Core.AchievementAC,
    achievementAwardedToProfileId :: Core.ProfileRefAC,
    achievementAwardedByProfileId :: Core.ProfileRefAC,
    achievementAchievementDate :: GYTime,
    achievementAccepted :: Bool,
    achievementName :: Text,
    achievementDescription :: Text,
    achievementImageURI :: Text,
    achievementThumbnailURI :: Text,
    achievementOtherMetadata :: [(Text, Text)],
    achievementTxHash :: Maybe Text,
    achievementSlot :: Maybe Integer,
    achievementOutputIndex :: Maybe Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievement", CamelToSnake]] AchievementResponse

instance ToSchema AchievementResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievement")

achievementToResponse :: Core.Achievement -> AchievementResponse
achievementToResponse a =
  AchievementResponse
    { achievementId = Core.achievementId a,
      achievementAwardedToProfileId = Core.achievementAwardedToProfileId a,
      achievementAwardedByProfileId = Core.achievementAwardedByProfileId a,
      achievementAchievementDate = Core.achievementAchievementDate a,
      achievementAccepted = Core.achievementAccepted a,
      achievementName = Core.achievementName a,
      achievementDescription = Core.achievementDescription a,
      achievementImageURI = Core.achievementImageURI a,
      achievementThumbnailURI = deriveThumbnailUri (Core.achievementImageURI a),
      achievementOtherMetadata = Core.achievementOtherMetadata a,
      achievementTxHash = Core.achievementTxHash a,
      achievementSlot = Core.achievementSlot a,
      achievementOutputIndex = Core.achievementOutputIndex a
    }

-- | Enriched achievement with resolved profile information for awarded-to and awarded-by.
-- Both profiles use 'ProfileResponse' (which carries 'profileType') because either
-- practitioners or organizations can award/receive achievements.
data AchievementInformationResponse = AchievementInformationResponse
  { achievementInfoId :: Core.AchievementAC,
    achievementInfoAchievementDate :: GYTime,
    achievementInfoAccepted :: Bool,
    achievementInfoName :: Text,
    achievementInfoDescription :: Text,
    achievementInfoImageURI :: Text,
    achievementInfoThumbnailURI :: Text,
    achievementInfoOtherMetadata :: [(Text, Text)],
    achievementInfoTxHash :: Maybe Text,
    achievementInfoSlot :: Maybe Integer,
    achievementInfoOutputIndex :: Maybe Int,
    achievementInfoAwardedTo :: ProfileResponse,
    achievementInfoAwardedBy :: ProfileResponse
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementInfo", CamelToSnake]] AchievementInformationResponse

instance ToSchema AchievementInformationResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementInfo")

achievementInformationToResponse ::
  Core.Profile ->
  Core.Profile ->
  Core.Achievement ->
  AchievementInformationResponse
achievementInformationToResponse awardedTo awardedBy a =
  AchievementInformationResponse
    { achievementInfoId = Core.achievementId a,
      achievementInfoAchievementDate = Core.achievementAchievementDate a,
      achievementInfoAccepted = Core.achievementAccepted a,
      achievementInfoName = Core.achievementName a,
      achievementInfoDescription = Core.achievementDescription a,
      achievementInfoImageURI = Core.achievementImageURI a,
      achievementInfoThumbnailURI = deriveThumbnailUri (Core.achievementImageURI a),
      achievementInfoOtherMetadata = Core.achievementOtherMetadata a,
      achievementInfoTxHash = Core.achievementTxHash a,
      achievementInfoSlot = Core.achievementSlot a,
      achievementInfoOutputIndex = Core.achievementOutputIndex a,
      achievementInfoAwardedTo = profileToResponse awardedTo,
      achievementInfoAwardedBy = profileToResponse awardedBy
    }

data OrganizationProfileResponse = OrganizationProfileResponse
  { organizationId :: Core.ProfileRefAC,
    organizationName :: Text,
    organizationDescription :: Text,
    organizationImageURI :: Text,
    organizationThumbnailURI :: Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "organization", CamelToSnake]] OrganizationProfileResponse

instance ToSchema OrganizationProfileResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "organization")

organizationProfileToResponse :: T.OrganizationProfileInformation -> OrganizationProfileResponse
organizationProfileToResponse o =
  OrganizationProfileResponse
    { organizationId = T.organizationId o,
      organizationName = T.organizationName o,
      organizationDescription = T.organizationDescription o,
      organizationImageURI = T.organizationImageURI o,
      organizationThumbnailURI = deriveThumbnailUri (T.organizationImageURI o)
    }

-- * Unified search (snake_case JSON per backend-api-requirements §9)

data SearchResults = SearchResults
  { searchResultsQuery :: Text,
    searchResultsTotal :: Int,
    searchResultsPractitioners :: SearchGroup,
    searchResultsOrganizations :: SearchGroup,
    searchResultsAchievements :: SearchGroup
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchResults", CamelToSnake]] SearchResults

instance ToSchema SearchResults where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchResults")

data SearchGroup = SearchGroup
  { searchGroupTotal :: Int,
    searchGroupItems :: [SearchHit]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchGroup", CamelToSnake]] SearchGroup

instance ToSchema SearchGroup where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchGroup")

data SearchHit = SearchHit
  { searchHitId :: Text,
    searchHitTitle :: Text,
    searchHitSubtitle :: Text,
    searchHitBadges :: [Text],
    searchHitStatus :: Maybe Text,
    searchHitTarget :: SearchTarget
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchHit", CamelToSnake]] SearchHit

instance ToSchema SearchHit where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchHit")

data SearchTarget = SearchTarget
  { searchTargetKind :: Text,
    searchTargetId :: Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "searchTarget", CamelToSnake]] SearchTarget

instance ToSchema SearchTarget where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "searchTarget")

-- * Lineage graph (snake_case JSON per backend-api-requirements §10)

data LineageGraphData = LineageGraphData
  { lineageGraphDataNodes :: [LineageNode],
    lineageGraphDataEdges :: [LineageEdge]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageGraphData", CamelToSnake]] LineageGraphData

instance ToSchema LineageGraphData where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageGraphData")

data LineageNode = LineageNode
  { lineageNodeProfileId :: Core.ProfileRefAC,
    lineageNodeName :: Text,
    lineageNodeImageUri :: Text,
    lineageNodeThumbnailUri :: Text,
    lineageNodeProfileType :: Core.ProfileType
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageNode", CamelToSnake]] LineageNode

instance ToSchema LineageNode where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageNode")

data LineageEdge = LineageEdge
  { lineageEdgeFrom :: Core.ProfileRefAC,
    lineageEdgeTo :: Core.ProfileRefAC,
    lineageEdgeDate :: GYTime
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "lineageEdge", CamelToSnake]] LineageEdge

instance ToSchema LineageEdge where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "lineageEdge")

-- * Explorer page aggregates (backend-api-requirements §12.5)

-- | Accepted vs pending achievement counts per calendar month.
data AchievementsMonthlyStatsResponse = AchievementsMonthlyStatsResponse
  { achievementsMonthlyStatsMonth :: Text,
    achievementsMonthlyStatsAccepted :: Int,
    achievementsMonthlyStatsPending :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementsMonthlyStats", CamelToSnake]] AchievementsMonthlyStatsResponse

instance ToSchema AchievementsMonthlyStatsResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementsMonthlyStats")

data AchievementsPageResponse = AchievementsPageResponse
  { achievementsPageItems :: [AchievementResponse],
    achievementsPageTotal :: Int,
    achievementsPageMonthly :: [AchievementsMonthlyStatsResponse]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "achievementsPage", CamelToSnake]] AchievementsPageResponse

instance ToSchema AchievementsPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "achievementsPage")

data ProfilesPageResponse = ProfilesPageResponse
  { profilesPageItems :: [ProfileResponse],
    profilesPageTotal :: Int,
    profilesPageFrequency :: [(Core.ProfileType, Int)]
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profilesPage", CamelToSnake]] ProfilesPageResponse

instance ToSchema ProfilesPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "profilesPage")

-- | Organization explorer page: one page of organization profiles + total.
-- Collapses the frontend's per-row @GET \/organization\/{id}@ (N+1) into a
-- single response, mirroring 'PractitionerExplorerPageResponse'.
data OrganizationExplorerPageResponse = OrganizationExplorerPageResponse
  { organizationExplorerPageItems :: [OrganizationProfileResponse],
    organizationExplorerPageTotal :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "organizationExplorerPage", CamelToSnake]] OrganizationExplorerPageResponse

instance ToSchema OrganizationExplorerPageResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "organizationExplorerPage")

-- * §12.1 Dashboard

-- | Top organization by active member count.
data TopOrganizationResponse = TopOrganizationResponse
  { topOrganizationOrganization :: OrganizationProfileResponse,
    topOrganizationMemberCount :: Int
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "topOrganization", CamelToSnake]] TopOrganizationResponse

instance ToSchema TopOrganizationResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "topOrganization")

-- | Build a 'TopOrganizationResponse' from an org profile response and member count.
topOrganizationResponse :: OrganizationProfileResponse -> Int -> TopOrganizationResponse
topOrganizationResponse org count =
  TopOrganizationResponse
    { topOrganizationOrganization = org,
      topOrganizationMemberCount = count
    }

-- * Activity feed (§ activity endpoint)

-- | Human-readable context for an activity event.
data ActivityEventDetails = ActivityEventDetails
  { activityEventDetailsTitle :: Text,
    activityEventDetailsBody :: Maybe Text,
    activityEventDetailsActorName :: Maybe Text,
    activityEventDetailsTargetName :: Maybe Text
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "activityEventDetails", CamelToSnake]] ActivityEventDetails

instance ToSchema ActivityEventDetails where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "activityEventDetails")

-- | Single activity feed item.
data ActivityEventResponse = ActivityEventResponse
  { activityEventEventType :: ActivityEventType,
    activityEventActorId :: Core.ProfileRefAC,
    activityEventTargetId :: Maybe Core.ProfileRefAC,
    activityEventTimestamp :: GYTime,
    activityEventDetails :: ActivityEventDetails
  }
  deriving stock (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "activityEvent", CamelToSnake]] ActivityEventResponse

instance ToSchema ActivityEventResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "activityEvent")

-- | Derive the thumbnail URL shown in API responses from an image URI.
-- Today mirrors @image_uri@; may later resolve cached or CDN URLs.
deriveThumbnailUri :: Text -> Text
deriveThumbnailUri = id

-- ---------------------------------------------------------------------------------------------

-- * Governance service status

--
-- The freshness contract. Every one of these fields exists so a reader can tell "the chain says
-- nothing happened" from "our index has not caught up yet" — a registry that cannot distinguish
-- those two publishes an absence as a fact.

-- | How far behind the chain our index is.
data SyncStatus = SyncStatus
  { syncEpoch :: Int,
    syncSlot :: Integer,
    syncBlockTime :: UTCTime,
    -- | Seconds between the tip block's time and now. Pre-cast in @palmares.sync_state@ because
    -- it is the one value there that is arithmetic rather than a column.
    syncLagSeconds :: Int,
    -- | The probe's verdict, so a client sees the same answer @\/ready@ gave without a second
    -- request and without reimplementing the thresholds.
    syncIsReady :: Bool,
    -- | What produced these numbers. A constant today, and published anyway: when a second
    -- indexer exists, a consumer must be able to tell which one answered.
    syncSource :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "sync", CamelToSnake]] SyncStatus

instance ToSchema SyncStatus where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "sync")

-- | The protocol parameters a governance client needs to interpret a tally.
--
-- Echoed rather than applied: the API publishes the thresholds and the numbers, and a reader
-- checks our arithmetic. A tally without the threshold it was measured against is a number
-- nobody can audit.
--
-- The threshold lists are @(name, value)@ pairs rather than a record, because the set is
-- protocol-version dependent — a hard fork adds a parameter group — and a record would turn that
-- into a breaking schema change. The names are db-sync's own column names, so a reader can look
-- any of them up in @palmares.thresholds@.
data EpochParamsSummary = EpochParamsSummary
  { epochParamsEpoch :: Int,
    -- | The LIFETIME, not the voting window: the ledger sets
    -- @expiration = proposed_epoch + lifetime + 1@, so this reads 6 on preprod while the observed
    -- delta on all 131 actions is 7. Anything that needs the last votable epoch reads
    -- @palmares.action_window@; this is the parameter, published as the parameter.
    epochParamsGovActionLifetime :: Int,
    epochParamsGovActionDeposit :: Integer,
    epochParamsDrepDeposit :: Integer,
    epochParamsDrepActivity :: Int,
    epochParamsCommitteeMinSize :: Int,
    epochParamsCommitteeMaxTermLength :: Int,
    epochParamsDrepThresholds :: [(Text, Double)],
    epochParamsPoolThresholds :: [(Text, Double)]
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "epochParams", CamelToSnake]] EpochParamsSummary

instance ToSchema EpochParamsSummary where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "epochParams")

-- | @GET \/status@: what this service is, how fresh it is, and the parameters its numbers mean
-- something against.
data StatusResponse = StatusResponse
  { -- | The network this instance serves, from configuration, and compared against
    -- @meta.network_name@ by @\/ready@. A registry pointed at the wrong network would answer
    -- every question confidently and wrongly.
    statusNetwork :: Text,
    statusGovernance :: SyncStatus,
    statusEpochParams :: EpochParamsSummary
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "status", CamelToSnake]] StatusResponse

instance ToSchema StatusResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "status")

-- ---------------------------------------------------------------------------------------------

-- * DReps

-- | One row of @GET \/dreps@: everything the delegation-discovery list shows about a DRep.
--
-- @id@ is the CIP-129 rendering and is DERIVED from @hex@ and @has_script@, which is why the
-- 'FromJSON' instance below is hand-written: the @palmares@ views deliberately never publish
-- db-sync's @drep_hash.view@ (the CIP-105 form, which uses one HRP for both credential kinds and
-- therefore cannot be compared against Koios, GovTool or a wallet), so the canonical id is
-- computed here from the pair that does determine it.
--
-- @hex@ is published alongside @id@ rather than instead of it because it is what a Koios or
-- db-sync comparison joins on.
data DRepSummary = DRepSummary
  { drepSummaryId :: Core.DRepId,
    drepSummaryHex :: Text,
    drepSummaryHasScript :: Bool,
    drepSummaryStatus :: Core.DRepStatus,
    drepSummaryIsActive :: Bool,
    -- | The epoch the ledger will stop counting this DRep's power in if it does not vote.
    drepSummaryActiveUntilEpoch :: Maybe Int,
    drepSummaryGivenName :: Maybe Text,
    drepSummaryImageUrl :: Maybe Text,
    drepSummaryLanguage :: Maybe Text,
    -- | What became of the DRep's own CIP-119 metadata anchor, consumed from @palmares.anchor@.
    drepSummaryAnchorStatus :: Maybe Core.AnchorStatus,
    drepSummaryRegisteredAt :: Maybe UTCTime,
    -- | Whole days registered, summed over registration intervals. @Maybe@ because a credential
    -- that never registered has no interval to sum (D-17), and floored rather than rounded
    -- because \"733 days\" should mean 733 days have elapsed.
    drepSummaryAgeDays :: Maybe Int,
    -- | Lovelace, at 'drepSummaryVotingPowerEpoch'.
    --
    -- Zero, not null, when the ledger's distribution for that epoch does not include this DRep.
    -- Measured on preprod: 109 of 294 registered DReps are in that position, 8 of them WITH live
    -- delegations — a delegation made during an epoch is not in that epoch's snapshot, so its
    -- power really is zero for that epoch and arrives in the next one. Five more have power with
    -- no live delegator, their delegators having since closed their stake accounts.
    drepSummaryVotingPower :: Integer,
    drepSummaryVotingPowerEpoch :: Maybe Int,
    drepSummaryDelegatorCount :: Int,
    drepSummaryEligibleActions :: Int,
    drepSummaryVotesCast :: Int,
    drepSummaryParticipationRate :: Maybe Double,
    drepSummaryRationaleRate :: Maybe Double,
    -- | Still-open actions this DRep has not voted on. Reported beside participation rather than
    -- folded into it: a vote not yet due is not a vote missed.
    drepSummaryOpenActionsUnvoted :: Int,
    drepSummaryLastVoteAt :: Maybe UTCTime,
    -- | The epoch every metric above is measured at.
    drepSummaryAsOfEpoch :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "drepSummary", CamelToSnake]] DRepSummary

instance ToSchema DRepSummary where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "drepSummary")

-- | Decode a @palmares@ row, computing @id@ from @hex@ and @has_script@.
--
-- Hand-written for that one derived field; everything else is the generic mapping spelled out.
-- @UnitTests.GovDto@ round-trips a value through 'Data.Aeson.encode' and back, so a field added
-- above and forgotten here fails the suite rather than reaching a client as @null@.
instance FromJSON DRepSummary where
  parseJSON = withObject "DRepSummary" $ \o -> do
    hex <- o .: "hex"
    hasScript <- o .: "has_script"
    drepId <-
      maybe
        (fail ("DRepSummary.hex is not a 28-byte credential: " <> show (hex :: Text)))
        pure
        (Core.drepIdFromHex hasScript hex)
    DRepSummary
      <$> pure drepId
      <*> pure hex
      <*> pure hasScript
      <*> o .: "status"
      <*> o .: "is_active"
      <*> o .:? "active_until_epoch"
      <*> o .:? "given_name"
      <*> o .:? "image_url"
      <*> o .:? "language"
      <*> o .:? "anchor_status"
      <*> o .:? "registered_at"
      <*> o .:? "age_days"
      <*> o .: "voting_power"
      <*> o .:? "voting_power_epoch"
      <*> o .: "delegator_count"
      <*> o .: "eligible_actions"
      <*> o .: "votes_cast"
      <*> o .:? "participation_rate"
      <*> o .:? "rationale_rate"
      <*> o .: "open_actions_unvoted"
      <*> o .:? "last_vote_at"
      <*> o .: "as_of_epoch"

-- ---------------------------------------------------------------------------------------------

-- * The DRep profile

-- | Final votes, by verdict. The sample is the FINAL vote on each eligible action, so a DRep that
-- changed its mind is counted once.
data VoteCounts = VoteCounts
  { voteCountsYes :: Int,
    voteCountsNo :: Int,
    voteCountsAbstain :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "voteCounts", CamelToSnake]] VoteCounts

instance ToSchema VoteCounts where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "voteCounts")

-- | One governance action type's slice of a DRep's record.
--
-- All seven types always appear, even at zero: a missing row reads as \"no data\" while a zero row
-- reads as \"nothing to vote on\", and the difference matters when a DRep is being judged.
data TypeBreakdown = TypeBreakdown
  { typeBreakdownEligibleActions :: Int,
    typeBreakdownVotesCast :: Int,
    typeBreakdownYes :: Int,
    typeBreakdownNo :: Int,
    typeBreakdownAbstain :: Int,
    typeBreakdownParticipationRate :: Maybe Double
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "typeBreakdown", CamelToSnake]] TypeBreakdown

instance ToSchema TypeBreakdown where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "typeBreakdown")

-- | Every published number about a DRep's track record, with the ids of the formulas that
-- produced them.
--
-- @formula_ids@ is the point of the whole design: a reader who distrusts a number can resolve the
-- id at @\/metrics\/formulas@ and read the exact SQL that computed it. A metric without a
-- resolvable formula is an opinion with a decimal point.
--
-- The five rationale counters sum to @votes_cast@ by construction, and all three rates are @null@
-- rather than @0@ when their denominator is empty — \"n\/a\" and \"0%\" are different statements
-- about a person.
data DRepMetrics = DRepMetrics
  { drepMetricsAsOfEpoch :: Int,
    drepMetricsEligibleActions :: Int,
    drepMetricsVotesCast :: Int,
    drepMetricsOpenActionsUnvoted :: Int,
    drepMetricsParticipationRate :: Maybe Double,
    drepMetricsRationaleVerified :: Int,
    drepMetricsRationaleInline :: Int,
    drepMetricsRationaleUnverified :: Int,
    drepMetricsRationalePending :: Int,
    drepMetricsRationaleAbsent :: Int,
    drepMetricsRationaleCip100Valid :: Int,
    drepMetricsRationaleRate :: Maybe Double,
    drepMetricsVoteLatencyMedianHours :: Maybe Double,
    drepMetricsVoteLatencyP90Hours :: Maybe Double,
    drepMetricsVoteLatencySample :: Int,
    drepMetricsAgeDays :: Maybe Int,
    drepMetricsFinalVotes :: VoteCounts,
    -- | @(action_type, breakdown)@ pairs rather than an object, so the seven types keep a stable
    -- order and a new governance action type is an added element rather than a schema change.
    drepMetricsVotesByType :: [(Core.GovActionType, TypeBreakdown)],
    drepMetricsFormulaIds :: [Text]
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "drepMetrics", CamelToSnake]] DRepMetrics

instance ToSchema DRepMetrics where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "drepMetrics")

-- | One epoch of a DRep's voting power.
--
-- A MISSING epoch is not zero-filled: the ledger's distribution for that epoch simply did not
-- include this DRep, and inventing a row would turn an absence into a measurement. Measured on
-- the fixture DRep: 141 points over epochs 174-320, with 203-208 genuinely absent.
--
-- @delegator_count@ is @null@ for an epoch the delegator view cannot reconstruct, which is not the
-- same as a DRep having had no delegators.
data EpochPowerPoint = EpochPowerPoint
  { epochPowerEpoch :: Int,
    epochPowerLovelace :: Integer,
    epochPowerDelegatorCount :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "epochPower", CamelToSnake]] EpochPowerPoint

instance ToSchema EpochPowerPoint where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "epochPower")

-- | How a DRep's delegator base moved over the retention window.
--
-- All five counters are published, not just the rate, because the rate alone cannot distinguish
-- \"kept all ten\" from \"lost ninety and kept ten\". @window_epochs@ is echoed so the number is
-- interpretable without reading the catalog.
--
-- The numbers come from running @delegator_retention_rate_v1.sql@ itself. "Delegators it HAD
-- then" is a set reconstructed from delegation intervals, not the set of addresses that ever
-- delegated: measured on the fixture DRep, the cumulative reading gave 26 previous delegators and
-- a retention rate of 0.42 where the real answer is 11 and 1.0.
-- The field names are the CATALOG's column names, not shorter ones: this block is decoded
-- straight out of @delegator_retention_rate_v1.sql@, the statement @\/metrics\/formulas@
-- publishes, so renaming them here would mean an aliasing layer whose only job is to let two
-- names for one number drift apart.
data DelegatorStats = DelegatorStats
  { delegatorStatsDelegatorCount :: Int,
    delegatorStatsDelegatorCountPrev :: Int,
    delegatorStatsDelegatorsRetained :: Int,
    delegatorStatsDelegatorsJoined :: Int,
    delegatorStatsDelegatorsLeft :: Int,
    delegatorStatsDelegatorRetentionRate :: Maybe Double,
    delegatorStatsWindowEpochs :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "delegatorStats", CamelToSnake]] DelegatorStats

instance ToSchema DelegatorStats where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "delegatorStats")

-- | One delegation.
--
-- @lovelace@ is the stake the ledger counted at the latest snapshot and is @null@ when the address
-- had no stake in it — a delegation made this epoch is real but not yet weighed.
data DelegatorRow = DelegatorRow
  { delegatorRowStakeAddress :: Text,
    delegatorRowLovelace :: Maybe Integer,
    delegatorRowDelegatedAt :: Core.ChainPoint,
    -- | False for a delegation that has since been superseded or whose stake account closed.
    delegatorRowIsCurrent :: Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "delegatorRow", CamelToSnake]] DelegatorRow

instance ToSchema DelegatorRow where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "delegatorRow")

-- | One DRep certificate.
--
-- @kind@ comes from @drep_registration.deposit@ and nowhere else, because that is the only place
-- db-sync records it: positive is a registration, negative a retirement, null a metadata update.
data DRepUpdateRow = DRepUpdateRow
  { drepUpdateKind :: Core.DRepUpdateKind,
    drepUpdateAt :: Core.ChainPoint,
    drepUpdateDeposit :: Maybe Integer,
    drepUpdateAnchorUrl :: Maybe Text,
    drepUpdateAnchorStatus :: Maybe Core.AnchorStatus
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "drepUpdate", CamelToSnake]] DRepUpdateRow

instance ToSchema DRepUpdateRow where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "drepUpdate")

-- | One reference from a CIP-119 metadata document.
data AnchorReference = AnchorReference
  { anchorReferenceLabel :: Maybe Text,
    anchorReferenceUri :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "anchorReference", CamelToSnake]] AnchorReference

instance ToSchema AnchorReference where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "anchorReference")

-- | A DRep's own CIP-119 metadata, as db-sync fetched and parsed it.
--
-- Served ONLY when the anchor's verdict is @valid@ — a document whose hash did not match the
-- on-chain commitment is not this DRep's statement about itself, whatever it says, and publishing
-- it under their name would be the registry asserting something it cannot verify.
data AnchorContent = AnchorContent
  { anchorContentGivenName :: Maybe Text,
    anchorContentObjectives :: Maybe Text,
    anchorContentMotivations :: Maybe Text,
    anchorContentQualifications :: Maybe Text,
    anchorContentImageUrl :: Maybe Text,
    anchorContentPaymentAddress :: Maybe Text,
    anchorContentReferences :: [AnchorReference]
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "anchorContent", CamelToSnake]] AnchorContent

instance ToSchema AnchorContent where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "anchorContent")

-- | @GET \/drep\/{id}@ and @GET \/pages\/drep\/{id}@: one DRep's whole public record.
--
-- One response and one handler on two paths. @\/pages\/…@ is the canonical path a screen renders;
-- the bare path is the alias for an API consumer who does not want the page framing. There is
-- deliberately no second DTO, because two DTOs for one screen is how a field gets fixed in one and
-- not the other.
--
-- @votes@ and @timeline@ are NOT here yet: their row types belong to @GET \/votes@ and
-- @GET \/activity@, and inventing them twice is the mistake the paragraph above warns about. Each
-- arrives as a new optional field, which is a minor Swagger bump by the same rule that covers the
-- attestation fields.
data DRepDetailResponse = DRepDetailResponse
  { drepDetailDrep :: DRepSummary,
    drepDetailMetrics :: DRepMetrics,
    drepDetailPowerByEpoch :: [EpochPowerPoint],
    drepDetailDelegatorStats :: DelegatorStats,
    drepDetailTopDelegators :: [DelegatorRow],
    drepDetailUpdates :: [DRepUpdateRow],
    drepDetailAnchorContent :: Maybe AnchorContent
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "drepDetail", CamelToSnake]] DRepDetailResponse

instance ToSchema DRepDetailResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "drepDetail")

-- ---------------------------------------------------------------------------------------------

-- * Governance actions

-- | A governance action's outcome and the four epochs behind it.
--
-- The four @*_epoch@ columns are published ALONGSIDE the single-valued @state@, because they are
-- not mutually exclusive and the @state@ is a reading of them in a fixed order: an enacted action
-- carries @ratified_epoch@ too, and most expired actions carry @dropped_epoch@. A reader who
-- disagrees with our reading can apply their own to the same four numbers.
--
-- Measured on preprod's 131 proposals: the five states partition them exactly — 103 expired, 11
-- enacted, 11 proposed, 6 dropped, 0 ratified. Zero @ratified@ because every ratified action was
-- enacted the following epoch, and @enacted_epoch = ratified_epoch + 1@ on all eleven.
--
-- @state@ and VOTABILITY can disagree: an action whose @expired_epoch@ is the current epoch reads
-- as @expired@ while its window is still open, which is why @last_votable_epoch@ is published
-- separately and is the authority on whether a vote is still possible.
data GovActionLifecycle = GovActionLifecycle
  { govActionLifecycleState :: Core.GovActionState,
    govActionLifecycleRatifiedEpoch :: Maybe Int,
    govActionLifecycleEnactedEpoch :: Maybe Int,
    govActionLifecycleExpiredEpoch :: Maybe Int,
    govActionLifecycleDroppedEpoch :: Maybe Int,
    govActionLifecycleFormulaId :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "govActionLifecycle", CamelToSnake]] GovActionLifecycle

instance ToSchema GovActionLifecycle where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "govActionLifecycle")

-- | One row of @GET \/gov-actions@.
--
-- @title@ and @abstract@ come from the action's CIP-108 metadata and are @null@ far more often
-- than a reader expects: measured, only 7 of preprod's 131 proposals have fetched metadata, so a
-- list that showed only titled actions would show 7 rows.
data GovActionSummary = GovActionSummary
  { govActionSummaryId :: Core.GovActionId,
    -- | The same action in CIP-129 form, so no consumer needs a bech32 implementation.
    govActionSummaryBech32 :: Text,
    govActionSummaryType :: Core.GovActionType,
    govActionSummaryTitle :: Maybe Text,
    govActionSummaryAbstract :: Maybe Text,
    govActionSummaryAnchorStatus :: Maybe Core.AnchorStatus,
    govActionSummaryProposedAt :: Core.ChainPoint,
    govActionSummaryExpiresEpoch :: Maybe Int,
    -- | The LAST epoch a vote can still be cast in. The authority on votability, which @state@
    -- is not: the ledger's rule is @currentEpoch \<= gasExpiresAfter@ AND the action still being
    -- in the proposals set, and this column is that rule applied.
    govActionSummaryLastVotableEpoch :: Maybe Int,
    govActionSummaryLifecycle :: GovActionLifecycle,
    govActionSummaryDeposit :: Maybe Integer,
    govActionSummaryReturnAddress :: Maybe Text,
    -- | Lovelace, for a TreasuryWithdrawals action; @null@ for every other type.
    govActionSummaryTreasuryAmount :: Maybe Integer,
    govActionSummaryVotesCast :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "govActionSummary", CamelToSnake]] GovActionSummary

instance ToSchema GovActionSummary where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "govActionSummary")

-- | Decode a @palmares.gov_action@ row, computing both id forms from @tx_hash@ and @index@.
--
-- Hand-written for the same reason 'DRepSummary''s instance is: the identifiers are derived, and
-- deriving them here means no row can reach a client carrying one form and not the other.
instance FromJSON GovActionSummary where
  parseJSON = withObject "GovActionSummary" $ \o -> do
    txHex <- o .: "tx_hash"
    ix <- o .: "index"
    (gid, bech) <-
      maybe
        (fail ("GovActionSummary: not a proposal id: " <> show (txHex :: Text) <> "#" <> show (ix :: Int)))
        pure
        (Core.govActionIdForms txHex ix)
    GovActionSummary
      <$> pure gid
      <*> pure bech
      <*> o .: "type"
      <*> o .:? "title"
      <*> o .:? "abstract"
      <*> o .:? "anchor_status"
      <*> o .: "proposed_at"
      <*> o .:? "expires_epoch"
      <*> o .:? "last_votable_epoch"
      <*> o .: "lifecycle"
      <*> o .:? "deposit"
      <*> o .:? "return_address"
      <*> o .:? "treasury_amount"
      <*> o .: "votes_cast"

-- ---------------------------------------------------------------------------------------------

-- * The governance action page

-- | One role's tally on one governance action.
--
-- __@basis@ is a field, not a footnote.__ @cast_votes_only@ means @yes_power \/ (yes_power +
-- no_power)@ over the votes ACTUALLY CAST. The ledger's ratification arithmetic compares against
-- TOTAL active voting power, which includes everyone who did not vote, so the two numbers differ
-- and only one of them is what we computed. A client that rendered this ratio as a prediction
-- would be wrong, which is why @lifecycle@ on the action is the authoritative outcome and this is
-- an observation.
--
-- @threshold@ is the parameter value in force at the epoch the action's voting window closed, and
-- @threshold_param@ echoes the column it came from so a reader can look the number up in
-- @palmares.thresholds@ themselves. Both are @null@ where no threshold applies: the committee
-- ratifies by member quorum and holds no stake, and SPOs do not vote on treasury withdrawals or
-- constitutional changes at all.
data VoteTally = VoteTally
  { voteTallyRole :: Core.VoterRole,
    voteTallyEpoch :: Int,
    voteTallyYesPower :: Integer,
    voteTallyNoPower :: Integer,
    voteTallyAbstainPower :: Integer,
    voteTallyYesCount :: Int,
    voteTallyNoCount :: Int,
    voteTallyAbstainCount :: Int,
    voteTallyRatio :: Maybe Double,
    voteTallyThreshold :: Maybe Double,
    voteTallyThresholdParam :: Maybe Text,
    voteTallyBasis :: Core.TallyBasis,
    voteTallyFormulaId :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "voteTally", CamelToSnake]] VoteTally

instance ToSchema VoteTally where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "voteTally")

-- | One payment a treasury withdrawal would make.
--
-- @enacted_at@ is an epoch-boundary chain point: no slot and no transaction hash, because the
-- ledger pays a withdrawal at an epoch boundary and there is no transaction to point at.
-- Publishing a slot there would be publishing a chain point no explorer could resolve. On preprod
-- it is always @null@ — 83 withdrawals are recorded and none has ever been enacted.
--
-- @paid_heuristic@ carries its warning in its name: @reward_rest@ has no governance-action key, so
-- matching a payment to a withdrawal by @(stake_address, spendable_epoch)@ is ambiguous when one
-- address receives two withdrawals in one epoch.
data TreasuryWithdrawalRow = TreasuryWithdrawalRow
  { treasuryWithdrawalBeneficiary :: Text,
    treasuryWithdrawalAmount :: Integer,
    treasuryWithdrawalEnactedAt :: Maybe ChainPointEpochOnly,
    treasuryWithdrawalPaidHeuristic :: Maybe Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "treasuryWithdrawal", CamelToSnake]] TreasuryWithdrawalRow

instance ToSchema TreasuryWithdrawalRow where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "treasuryWithdrawal")

-- | A chain point for something that happened at an epoch boundary rather than in a transaction.
--
-- The same shape as 'Core.ChainPoint' with @slot@ and @tx_hash@ always absent, as a distinct type
-- so a handler cannot accidentally fill them: @time@ is the first block of the epoch, which is
-- the closest thing to a timestamp a ledger event has.
data ChainPointEpochOnly = ChainPointEpochOnly
  { chainPointEpochOnlySlot :: Maybe Integer,
    chainPointEpochOnlyEpoch :: Int,
    chainPointEpochOnlyTime :: UTCTime,
    chainPointEpochOnlyTxHash :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "chainPointEpochOnly", CamelToSnake]] ChainPointEpochOnly

instance ToSchema ChainPointEpochOnly where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "chainPointEpochOnly")

-- | One protocol parameter a ParameterChange action would change, and its CIP-1694 group.
--
-- The group matters because it decides the DRep threshold: a ParameterChange's threshold is the
-- MAXIMUM over the groups it touches, so a reader who wants to check our threshold needs to see
-- which groups we read.
data ParamChangeRow = ParamChangeRow
  { paramChangeParam :: Text,
    paramChangeGroup :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "paramChange", CamelToSnake]] ParamChangeRow

instance ToSchema ParamChangeRow where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "paramChange")

-- | Who proposed an action, and how many they have proposed.
--
-- @actions_count@ is the whole point of including this: one proposal says nothing about a
-- proposer, and a track record is what this registry is for.
data ProposerSummary = ProposerSummary
  { proposerStakeAddress :: Text,
    proposerActionsCount :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "proposer", CamelToSnake]] ProposerSummary

instance ToSchema ProposerSummary where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "proposer")

-- | A governance action's CIP-108 metadata, served only when its anchor verdict is @valid@.
--
-- Same gate as a DRep's CIP-119 content and for the same reason: a document whose hash did not
-- match the on-chain commitment is not this proposal's statement of itself.
data GovActionAnchorContent = GovActionAnchorContent
  { govActionAnchorTitle :: Maybe Text,
    govActionAnchorAbstract :: Maybe Text,
    govActionAnchorMotivation :: Maybe Text,
    govActionAnchorRationale :: Maybe Text,
    govActionAnchorReferences :: [AnchorReference]
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "govActionAnchor", CamelToSnake]] GovActionAnchorContent

instance ToSchema GovActionAnchorContent where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "govActionAnchor")

-- | @GET \/gov-action\/{id}@ and @GET \/pages\/gov-action\/{id}@: one action's whole record.
--
-- One handler, two paths, one response type, for the reason 'DRepDetailResponse' gives.
--
-- @tallies@ carries one entry per role that actually voted, not a fixed three: a role with no
-- votes has no tally, and publishing a zero row would read as \"they voted and it came to zero\".
--
-- @votes@ and @timeline@ are absent for the same sequencing reason as on the DRep page — their row
-- types belong to @GET \/votes@ and @GET \/activity@.
data GovActionDetailResponse = GovActionDetailResponse
  { govActionDetailAction :: GovActionSummary,
    govActionDetailTallies :: [VoteTally],
    govActionDetailWithdrawals :: [TreasuryWithdrawalRow],
    govActionDetailParamChanges :: [ParamChangeRow],
    govActionDetailProposer :: Maybe ProposerSummary,
    govActionDetailAnchorContent :: Maybe GovActionAnchorContent
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "govActionDetail", CamelToSnake]] GovActionDetailResponse

instance ToSchema GovActionDetailResponse where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "govActionDetail")

-- ---------------------------------------------------------------------------------------------

-- * Votes

-- | The rationale anchor attached to a vote, as far as db-sync got with it.
data VoteAnchor = VoteAnchor
  { voteAnchorUrl :: Maybe Text,
    voteAnchorStatus :: Core.AnchorStatus,
    -- | Whether the fetched document validated against CIP-100's schema. @null@ when nothing was
    -- fetched; distinct from @status@, which is about the hash and the fetch.
    voteAnchorCip100Valid :: Maybe Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "voteAnchor", CamelToSnake]] VoteAnchor

instance ToSchema VoteAnchor where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "voteAnchor")

-- | One vote, as cast — including the ones later superseded.
--
-- __Re-votes are rows, not a problem to hide.__ Changing one's mind is legal and is part of a
-- public record, so every row is returned with @revote_count@ saying how many exist for that
-- (voter, action) pair and @is_final@ / @is_first@ marking which one a verdict or a latency is
-- measured from. On preprod the worst pair has 21,626 rows — a committee hot key voting on one
-- action over and over during the epoch-187 stress test.
--
-- __D-24: @voter_id@ for a committee vote is the COLD credential__, which is the identity that
-- survives a hot-key rotation and the one a reader can follow. The hot key that actually signed is
-- published beside it as @voter_hot_hash@, because that is what the transaction contains.
data VoteRecord = VoteRecord
  { voteRecordGovActionId :: Core.GovActionId,
    voteRecordGovActionBech32 :: Text,
    voteRecordGovActionType :: Core.GovActionType,
    voteRecordGovActionTitle :: Maybe Text,
    voteRecordVoterRole :: Core.VoterRole,
    -- | CIP-129 for a DRep (@drep1y…@) or a committee cold key (@cc_cold1…@); CIP-5 for a stake
    -- pool (@pool1…@), because that is the only form any Cardano tool shows for a pool.
    voteRecordVoterId :: Text,
    voteRecordVoterHotHash :: Maybe Text,
    voteRecordVoterName :: Maybe Text,
    voteRecordVerdict :: Core.Vote,
    voteRecordCastAt :: Core.ChainPoint,
    -- | Hours between the action being proposed and THIS row being cast. Per row rather than per
    -- voter, so a re-vote shows how long the second thought took; @vote_latency_median_hours_v1@
    -- samples the @is_first@ rows, which is why that flag is published.
    voteRecordLatencyHours :: Maybe Double,
    voteRecordIsFinal :: Bool,
    voteRecordIsFirst :: Bool,
    voteRecordRevoteCount :: Int,
    voteRecordAnchor :: Maybe VoteAnchor,
    -- | The voter's power at the epoch the action's window closed. @null@ together with
    -- @voting_power_epoch@: a committee member holds no stake, and a DRep absent from the
    -- distribution for that epoch has no recorded power for it.
    voteRecordVotingPower :: Maybe Integer,
    voteRecordVotingPowerEpoch :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)
  deriving (ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "voteRecord", CamelToSnake]] VoteRecord

instance ToSchema VoteRecord where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "voteRecord")

-- | Decode a @palmares.vote@ row, deriving both identifiers.
--
-- @voter_id@ is derived per role from the hash and the script flag, and the governance action's
-- two forms from its transaction hash and index — the same reason 'DRepSummary' and
-- 'GovActionSummary' hand-write theirs.
instance FromJSON VoteRecord where
  parseJSON = withObject "VoteRecord" $ \o -> do
    txHex <- o .: "tx_hash"
    ix <- o .: "index"
    (gid, bech) <-
      maybe (fail ("VoteRecord: not a proposal id: " <> show (txHex :: Text))) pure
        (Core.govActionIdForms txHex (ix :: Int))
    role <- o .: "voter_role"
    idHex <- o .: "voter_id_hash"
    hasScript <- o .:? "has_script" .!= False
    voterId <-
      maybe (fail ("VoteRecord: not a credential: " <> show (idHex :: Text))) pure
        (Core.voterIdFor role hasScript idHex)
    VoteRecord
      <$> pure gid
      <*> pure bech
      <*> o .: "gov_action_type"
      <*> o .:? "gov_action_title"
      <*> pure role
      <*> pure voterId
      <*> o .:? "voter_hot_hash"
      <*> o .:? "voter_name"
      <*> o .: "verdict"
      <*> o .: "cast_at"
      <*> o .:? "latency_hours"
      <*> o .: "is_final"
      <*> o .: "is_first"
      <*> o .: "revote_count"
      <*> o .:? "anchor"
      <*> o .:? "voting_power"
      <*> o .:? "voting_power_epoch"
