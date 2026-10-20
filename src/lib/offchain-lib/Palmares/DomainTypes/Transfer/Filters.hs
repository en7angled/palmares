{-# LANGUAGE OverloadedStrings #-}

-- | Query listing filter record types and query-param constructors (shared by query-api handlers).
module Palmares.DomainTypes.Transfer.Filters
  ( ProfileFilter (..),
    AchievementFilter (..),
    ActivityFilter (..),
    profileFilterFromParams,
    achievementFilterFromParams,
    activityFilterFromParams,
    DRepFilter (..),
    emptyDRepFilter,
  )
where

import Data.Text (Text)
import Data.Int (Int64)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types qualified as Core
-- The Belt System's PascalCase ActivityEventType (ProfileCreated | AchievementAwarded |
-- AchievementAccepted) still lives in Transfer.OrderBy and still backs the inherited /activity
-- feed. Palmares.DomainTypes.Core.Types now exports the snake_case GOVERNANCE one of the same
-- name, so the inherited name is hidden here until T-API-15 replaces that feed and deletes it.
import Palmares.DomainTypes.Core.Types hiding (ActivityEventType)
import Palmares.DomainTypes.Transfer.OrderBy (ActivityEventType)
import GeniusYield.Types (GYTime)

optionalNonEmpty :: [a] -> Maybe [a]
optionalNonEmpty xs = if null xs then Nothing else Just xs

-- | Optional filters for the profiles listing endpoint.
data ProfileFilter = ProfileFilter
  { profileFilterId :: Maybe [ProfileRefAC], -- ^ Restrict to these profile IDs
    profileFilterType :: Maybe ProfileType, -- ^ Practitioner or Organization
    profileFilterName :: Maybe Text, -- ^ Exact or prefix name match
    profileFilterDescription :: Maybe Text, -- ^ Substring match on description
    profileFilterTextSearch :: Maybe Text, -- ^ Free-text search across name and description
    -- | Registered at or after this chain slot. A slot, not a timestamp: @created_at_slot@ is
    -- the only time a projection row carries (inherited fix #5), and comparing on it keeps the
    -- indexed column in play. Handlers translate a @since@ query param with
    -- 'Palmares.TxBuilding.Utils.utcToSlot'.
    profileFilterRegisteredAfterSlot :: Maybe Integer
  }

-- | Optional filters for the achievements listing endpoint.
data AchievementFilter = AchievementFilter
  { achievementFilterId :: Maybe [AchievementAC], -- ^ Restrict to these achievement asset classes
    achievementFilterAwardedToProfileId :: Maybe [ProfileRefAC], -- ^ Recipient profile IDs
    achievementFilterAwardedByProfileId :: Maybe [ProfileRefAC], -- ^ Issuer profile IDs
    achievementFilterIsAccepted :: Maybe Bool, -- ^ Acceptance status
    achievementFilterDateInterval :: (Maybe GYTime, Maybe GYTime), -- ^ Date range (from, to) inclusive
    achievementFilterTextSearch :: Maybe Text -- ^ Free-text search
  }

-- | Optional filters for the activity-feed endpoint.
data ActivityFilter = ActivityFilter
  { activityFilterEventType :: Maybe ActivityEventType, -- ^ Restrict to this event type
    activityFilterActor :: Maybe ProfileRefAC, -- ^ Filter by the acting profile
    activityFilterSince :: Maybe GYTime -- ^ Only return events after this timestamp
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

-- | Build achievement filter from query params.
achievementFilterFromParams ::
  [AchievementAC] ->
  [ProfileRefAC] ->
  [ProfileRefAC] ->
  Maybe Bool ->
  Maybe GYTime ->
  Maybe GYTime ->
  Maybe Text ->
  AchievementFilter
achievementFilterFromParams achievementIds awardedToRefs awardedByRefs isAccepted fromTime toTime q =
  AchievementFilter
    { achievementFilterId = optionalNonEmpty achievementIds,
      achievementFilterAwardedToProfileId = optionalNonEmpty awardedToRefs,
      achievementFilterAwardedByProfileId = optionalNonEmpty awardedByRefs,
      achievementFilterIsAccepted = isAccepted,
      achievementFilterDateInterval = (fromTime, toTime),
      achievementFilterTextSearch = q
    }

-- | Build activity filter from query params.
activityFilterFromParams :: Maybe ActivityEventType -> Maybe ProfileRefAC -> Maybe GYTime -> Maybe ActivityFilter
activityFilterFromParams eventType actor since =
  case (eventType, actor, since) of
    (Nothing, Nothing, Nothing) -> Nothing
    _ ->
      Just
        ActivityFilter
          { activityFilterEventType = eventType,
            activityFilterActor = actor,
            activityFilterSince = since
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
