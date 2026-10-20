

{-# LANGUAGE ScopedTypeVariables #-}

-- | §12.5 explorer page aggregates ([backend-api-requirements.md](backend-api-requirements.md)).
module Query.Pages
  ( getAchievementsPage,
    getProfilesPage,
    getOrganizationExplorerPage,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.List (nub)
import Data.Map.Strict qualified as M
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime, nominalDay)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Palmares.DomainTypes.Core.Types
import GeniusYield.Types (GYTime, timeFromPOSIX)
import Query.Aggregates qualified as Agg
import Palmares.DomainTypes.Transfer.Filters qualified as F
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AchievementsPageResponse (..),
    OrganizationExplorerPageResponse (..),
    ProfilesPageResponse (..),
    achievementToResponse,
    organizationProfileToResponse,
    profileToResponse,
  )
import Query.Common qualified as C
import Query.Projected qualified as P
import QueryAppMonad (QueryAppMonad (..))
import Palmares.DomainTypes.Transfer.Filters
  ( achievementFilterFromParams,
    profileFilterFromParams,
  )
import Palmares.DomainTypes.Transfer.OrderBy

-- | Filter profiles by type only (counts and latest lists).
profileFilterOfType :: ProfileType -> F.ProfileFilter
profileFilterOfType pt =
  F.ProfileFilter Nothing (Just pt) Nothing Nothing Nothing Nothing



-- | Achievements explorer page.
getAchievementsPage ::
  Maybe Int ->
  Maybe Int ->
  [AchievementAC] ->
  [ProfileRefAC] ->
  [ProfileRefAC] ->
  Maybe Bool ->
  Maybe GYTime ->
  Maybe GYTime ->
  Maybe Text ->
  Maybe AchievementsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad AchievementsPageResponse
getAchievementsPage limit offset achievementIds awardedToRefs awardedByRefs accepted fromTime toTime q orderBy sortOrder = do
  let limitOffset = C.normalizeLimitOffset limit offset
      achFilter = Just $ achievementFilterFromParams achievementIds awardedToRefs awardedByRefs accepted fromTime toTime q
      order = C.normalizeOrder orderBy sortOrder
  items <- P.getAchievements limitOffset achFilter order
  total <- P.getAchievementsCount achFilter
  return
    AchievementsPageResponse
      { achievementsPageItems = map achievementToResponse items,
        achievementsPageTotal = total,
        -- The monthly histogram comes back with the metrics block (its source module is a rewrite).
        achievementsPageMonthly = []
      }

-- | Profiles explorer page (list + total + type frequency).
getProfilesPage ::
  Maybe Int ->
  Maybe Int ->
  [ProfileRefAC] ->
  Maybe ProfileType ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad ProfilesPageResponse
getProfilesPage limit offset profileRefs profileType q orderBy sortOrder = do
  let limitOffset = C.normalizeLimitOffset limit offset
      profileFilter = Just $ profileFilterFromParams profileRefs profileType q
      order = C.normalizeOrder orderBy sortOrder
  profiles <- P.getProfiles limitOffset profileFilter order
  total <- P.getProfilesCount profileFilter
  frequency <- P.getProfileTypeTotals
  return
    ProfilesPageResponse
      { profilesPageItems = map profileToResponse profiles,
        profilesPageTotal = total,
        profilesPageFrequency = frequency
      }


-- | Organization explorer page: one page of organization profiles + total, in a single
-- response, collapsing the frontend's per-row @GET /organization/{id}@ (N+1) into one call.
getOrganizationExplorerPage ::
  Maybe Int ->
  Maybe Int ->
  [ProfileRefAC] ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad OrganizationExplorerPageResponse
getOrganizationExplorerPage limit offset profileRefs q orderBy sortOrder = do
  let limitOffset = C.normalizeLimitOffset limit offset
      profileFilter = Just $ profileFilterFromParams profileRefs (Just Organization) q
      order = C.normalizeOrder orderBy sortOrder
  profiles <- P.getProfiles limitOffset profileFilter order
  total <- P.getProfilesCount profileFilter
  let pids = map profileId profiles
  -- Batch-load organization profiles (2 SQL queries instead of N)
  orgInfoMap <- P.getOrganizationProfilesBatch pids
  let items =
        [ organizationProfileToResponse info
          | p <- profiles,
            Just info <- [M.lookup (profileId p) orgInfoMap]
        ]
  return
    OrganizationExplorerPageResponse
      { organizationExplorerPageItems = items,
        organizationExplorerPageTotal = total
      }


