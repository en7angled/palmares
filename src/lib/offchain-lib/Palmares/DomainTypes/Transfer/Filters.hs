{-# LANGUAGE OverloadedStrings #-}

-- | Query listing filter record types and query-param constructors (shared by query-api handlers).
module Palmares.DomainTypes.Transfer.Filters
  ( ProfileFilter (..),
    AchievementFilter (..),
    ActivityFilter (..),
    profileFilterFromParams,
    achievementFilterFromParams,
    activityFilterFromParams,
  )
where

import Data.Text (Text)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types
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
    profileFilterRegisteredAfter :: Maybe UTCTime -- ^ Registered on or after this timestamp
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
      profileFilterRegisteredAfter = Nothing
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
