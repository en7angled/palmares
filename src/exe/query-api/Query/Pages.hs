

{-# LANGUAGE ScopedTypeVariables #-}

-- | §12.5 explorer page aggregates ([backend-api-requirements.md](backend-api-requirements.md)).
module Query.Pages
  ( getAttestationsPage,
    getProfilesPage,
    getOrganizationExplorerPage,
  )
where

import Data.Map.Strict qualified as M
import Data.Text (Text)
import Palmares.DomainTypes.Core.Types
import GeniusYield.Types (GYTime)
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AttestationsPageResponse (..),
    OrganizationExplorerPageResponse (..),
    ProfilesPageResponse (..),
    attestationToResponse,
    organizationProfileToResponse,
    profileToResponse,
  )
import Query.Common qualified as C
import Query.Projected qualified as P
import QueryAppMonad (QueryAppMonad (..))
import Palmares.DomainTypes.Transfer.Filters
  ( attestationFilterFromParams,
    profileFilterFromParams,
  )
import Palmares.DomainTypes.Transfer.OrderBy




-- | Attestations explorer page.
getAttestationsPage ::
  Maybe Int ->
  Maybe Int ->
  [AttestationAC] ->
  [ProfileRefAC] ->
  [ProfileRefAC] ->
  Maybe Bool ->
  Maybe GYTime ->
  Maybe GYTime ->
  Maybe Text ->
  Maybe AttestationsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad AttestationsPageResponse
getAttestationsPage limit offset attestationIds subjectRefs issuerRefs accepted fromTime toTime q orderBy sortOrder = do
  let limitOffset = C.legacyNormalizeLimitOffset limit offset
      achFilter = Just $ attestationFilterFromParams attestationIds subjectRefs issuerRefs accepted fromTime toTime q
      order = C.normalizeOrder orderBy sortOrder
  items <- P.getAttestations limitOffset achFilter order
  total <- P.getAttestationsCount achFilter
  return
    AttestationsPageResponse
      { attestationsPageItems = map attestationToResponse items,
        attestationsPageTotal = total,
        -- The monthly histogram comes back with the metrics block (its source module is a rewrite).
        attestationsPageMonthly = []
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
  let limitOffset = C.legacyNormalizeLimitOffset limit offset
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
  let limitOffset = C.legacyNormalizeLimitOffset limit offset
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


