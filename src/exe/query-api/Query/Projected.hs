{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant bracket" #-}
{-# HLINT ignore "Redundant pure" #-}
{-# HLINT ignore "Fuse on/on" #-}

module Query.Projected where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Reader.Class
import Data.Aeson (ToJSON)
import Data.Foldable (for_)
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Database.Esqueleto.Experimental
import Database.Esqueleto.Internal.Internal (unsafeSqlCastAs)
import Database.Persist qualified as P
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Filters qualified as C
import Palmares.DomainTypes.Transfer.Filters qualified as F
import Palmares.DomainTypes.Transfer.OrderBy
import Palmares.DomainTypes.Transfer.QueryResponses
  (     SearchGroup (..),
    SearchHit (..),
    SearchResults (..),
    SearchTarget (..),
  )
import Palmares.DomainTypes.Transfer.Types
import GeniusYield.Types (GYSlotConfig, GYTime, timeFromPOSIX, timeToPOSIX)
import Query.Common qualified as C
import QueryAppMonad
import Palmares.Storage
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.Utils (stringFromJSON)
import Palmares.TxBuilding.Utils (slotToUTC, utcToSlot)
import Palmares.WebAPI.Utils (escapeLikePattern)



-- | Build a case-insensitive SQL LIKE pattern for text search: @%<escaped lower q>%@.
-- Metacharacters in @q@ are escaped so a user-supplied @%@/@_@ matches literally.
likePat :: Text -> SqlExpr (Value Text)
likePat q = val (T.pack "%" <> escapeLikePattern (T.toLower q) <> T.pack "%")


-- | Apply sort direction (Asc/Desc) to an expression for orderBy.
orderByDir :: (PersistField a) => SortOrder -> SqlExpr (Value a) -> SqlExpr OrderBy
orderByDir so expr = case so of Asc -> asc expr; Desc -> desc expr

-- | Apply optional limit/offset in a select query.
applyLimitOffset :: Maybe (C.Limit, C.Offset) -> SqlQuery ()
applyLimitOffset Nothing = pure ()
applyLimitOffset (Just (l, o)) = do
  offset (fromIntegral o)
  limit (fromIntegral l)

-- | Add where_ clauses for an optional date interval (from, to).
whereDateInterval :: (Maybe GYTime, Maybe GYTime) -> SqlExpr (Value GYTime) -> SqlQuery ()
whereDateInterval (mf, mt) dateCol = case (mf, mt) of
  (Nothing, Nothing) -> pure ()
  (Just f, Nothing) -> where_ (dateCol >=. val f)
  (Nothing, Just t) -> where_ (dateCol <=. val t)
  (Just f, Just t) -> where_ (dateCol >=. val f &&. dateCol <=. val t)




applyAttestationFilter :: Maybe F.AttestationFilter -> SqlExpr (Entity AttestationProjection) -> SqlQuery ()
applyAttestationFilter Nothing _ = pure ()
applyAttestationFilter (Just F.AttestationFilter {..}) ap = do
  for_ attestationFilterId (\ids -> where_ (ap ^. AttestationProjectionAttestationId `in_` valList ids))
  for_ attestationFilterSubjectProfileId (\ids -> where_ (ap ^. AttestationProjectionSubjectProfileId `in_` valList ids))
  for_ attestationFilterIssuerProfileId (\ids -> where_ (ap ^. AttestationProjectionIssuerProfileId `in_` valList ids))
  for_ attestationFilterIsAccepted (\ac -> where_ (ap ^. AttestationProjectionIsAccepted ==. val ac))
  whereDateInterval attestationFilterDateInterval (ap ^. AttestationProjectionAttestationDate)
  for_
    attestationFilterTextSearch
    ( \q ->
        let pat = likePat q
         in where_ $
              (lower_ (unsafeSqlCastAs "text" (ap ^. AttestationProjectionAttestationId)) `like` pat)
                ||. (lower_ (unsafeSqlCastAs "text" (ap ^. AttestationProjectionSubjectProfileId)) `like` pat)
                ||. (lower_ (unsafeSqlCastAs "text" (ap ^. AttestationProjectionIssuerProfileId)) `like` pat)
                ||. (lower_ (ap ^. AttestationProjectionAttestationName) `like` pat)
                ||. (lower_ (ap ^. AttestationProjectionAttestationDescription) `like` pat)
    )



applyProfileFilter :: Maybe F.ProfileFilter -> SqlExpr (Entity ProfileProjection) -> SqlQuery ()
applyProfileFilter Nothing _ = pure ()
applyProfileFilter (Just F.ProfileFilter {..}) pp = do
  for_ profileFilterId (\ids -> where_ (pp ^. ProfileProjectionProfileId `in_` valList ids))
  for_ profileFilterType (\pt -> where_ (pp ^. ProfileProjectionProfileType ==. val pt))
  for_ profileFilterName (\nameSubstring -> where_ (lower_ (pp ^. ProfileProjectionProfileName) `like` likePat nameSubstring))
  for_ profileFilterDescription (\descriptionSubstring -> where_ (lower_ (pp ^. ProfileProjectionProfileDescription) `like` likePat descriptionSubstring))
  -- Text search: name, description, profile id; for Practitioners only, also match affiliated org id/name (§1.8)
  for_
    profileFilterTextSearch
    ( \q ->
        let pat = likePat q
            selfMatch =
              (lower_ (pp ^. ProfileProjectionProfileName) `like` pat)
                ||. (lower_ (pp ^. ProfileProjectionProfileDescription) `like` pat)
                ||. (lower_ (unsafeSqlCastAs "text" (pp ^. ProfileProjectionProfileId)) `like` pat)
         in where_ selfMatch
    )
  -- Filter by registration slot (created_at_slot >= cutoff); see fix #5 in Storage.hs
  for_ profileFilterRegisteredAfterSlot (\cutoff -> where_ (pp ^. ProfileProjectionCreatedAtSlot >=. val cutoff))



-- | Batch-load raw profile fields (name, description, imageURI) by id, for any
-- profile regardless of rank. Used to build placeholder practitioner info for
-- promotion edges whose profile has no rank projection yet. Skips missing ids.
getProfileProjectionsBatch ::
  (MonadIO m, MonadReader QueryAppContext m) =>
  [ProfileRefAC] ->
  m (M.Map ProfileRefAC (Text, Text, Text))
getProfileProjectionsBatch [] = return M.empty
getProfileProjectionsBatch pids = do
  pool <- asks pgPool
  let uniqPids = nub pids
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            pp <- from $ table @ProfileProjection
            where_ (pp ^. ProfileProjectionProfileId `in_` valList uniqPids)
            pure pp
          return $
            M.fromList
              [ ( profileProjectionProfileId r,
                  ( profileProjectionProfileName r,
                    profileProjectionProfileDescription r,
                    profileProjectionProfileImageURI r
                  )
                )
              | Entity _ r <- rows
              ]
      )
      pool

-- | Batch-load organization profiles for a list of IDs (single SQL query).
-- Skips IDs that are not found. Used by aggregate map builders to avoid N+1.
getOrganizationProfilesBatch ::
  (MonadIO m, MonadReader QueryAppContext m) =>
  [ProfileRefAC] ->
  m (M.Map ProfileRefAC OrganizationProfileInformation)
getOrganizationProfilesBatch [] = return M.empty
getOrganizationProfilesBatch oids = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            pp <- from $ table @ProfileProjection
            where_ (pp ^. ProfileProjectionProfileId `in_` valList (nub oids))
            where_ (pp ^. ProfileProjectionProfileType ==. val Organization)
            pure pp
          return $
            M.fromList
              [ ( profileProjectionProfileId prof,
                  OrganizationProfileInformation
                    { organizationId = profileProjectionProfileId prof,
                      organizationName = profileProjectionProfileName prof,
                      organizationDescription = profileProjectionProfileDescription prof,
                      organizationImageURI = profileProjectionProfileImageURI prof
                    }
                )
              | Entity _ prof <- rows
              ]
      )
      pool

getOrganizationProfile :: ProfileRefAC -> QueryAppMonad OrganizationProfileInformation
getOrganizationProfile profileRefAC = do
  pool <- asks pgPool
  runWithQueryErrorHandling $
    runSqlPool
      ( do
          mProf <- P.getBy (UniqueProfileProjection profileRefAC)
          case mProf of
            Nothing -> liftIO $ throwIO ProfileNotFound
            Just (Entity _ prof) ->
              return
                OrganizationProfileInformation
                  { organizationId = profileRefAC,
                    organizationName = profileProjectionProfileName prof,
                    organizationDescription = profileProjectionProfileDescription prof,
                    organizationImageURI = profileProjectionProfileImageURI prof
                  }
      )
      pool

getProfilesCount :: (MonadIO m, MonadReader QueryAppContext m) => Maybe F.ProfileFilter -> m Int
getProfilesCount maybeProfileFilter = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          cnt <- selectOne $ do
            pp <- from $ table @ProfileProjection
            applyProfileFilter maybeProfileFilter pp
            pure countRows
          pure (maybe 0 unValue cnt)
      )
      pool

getProfiles :: (MonadIO m, MonadReader QueryAppContext m) => Maybe (C.Limit, C.Offset) -> Maybe F.ProfileFilter -> Maybe (ProfilesOrderBy, SortOrder) -> m [Profile]
getProfiles maybeLimitOffset maybeProfileFilter maybeOrder = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            pp <- from $ table @ProfileProjection
            applyProfileFilter maybeProfileFilter pp
            case maybeOrder of
              Nothing -> pure ()
              Just (ob, so) ->
                case ob of
                  ProfilesOrderById -> orderBy [orderByDir so (pp ^. ProfileProjectionProfileId)]
                  ProfilesOrderByName -> orderBy [orderByDir so (pp ^. ProfileProjectionProfileName)]
                  ProfilesOrderByDescription -> orderBy [orderByDir so (pp ^. ProfileProjectionProfileDescription)]
                  ProfilesOrderByType -> orderBy [orderByDir so (pp ^. ProfileProjectionProfileType)]
                  ProfilesOrderByRegisteredAt -> orderBy [orderByDir so (pp ^. ProfileProjectionCreatedAtSlot)]
            applyLimitOffset maybeLimitOffset
            pure pp
          let toProfile pp =
                Profile
                  { profileId = profileProjectionProfileId pp,
                    profileName = profileProjectionProfileName pp,
                    profileDescription = profileProjectionProfileDescription pp,
                    profileImageURI = profileProjectionProfileImageURI pp,
                    profileType = profileProjectionProfileType pp
                  }
          pure (Prelude.map (toProfile . entityVal) rows)
      )
      pool



getAttestations :: (MonadIO m, MonadReader QueryAppContext m) => Maybe (C.Limit, C.Offset) -> Maybe F.AttestationFilter -> Maybe (AttestationsOrderBy, SortOrder) -> m [Attestation]
getAttestations maybeLimitOffset maybeAttestationFilter maybeOrder = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            ap <- from $ table @AttestationProjection
            applyAttestationFilter maybeAttestationFilter ap
            case maybeOrder of
              Nothing -> pure ()
              Just (ob, so) ->
                case ob of
                  AttestationsOrderById -> orderBy [orderByDir so (ap ^. AttestationProjectionAttestationId)]
                  AttestationsOrderByDate -> orderBy [orderByDir so (ap ^. AttestationProjectionAttestationDate)]
                  AttestationsOrderBySubject -> orderBy [orderByDir so (ap ^. AttestationProjectionSubjectProfileId)]
                  AttestationsOrderByIssuer -> orderBy [orderByDir so (ap ^. AttestationProjectionIssuerProfileId)]
                  AttestationsOrderByName -> orderBy [orderByDir so (ap ^. AttestationProjectionAttestationName)]
            applyLimitOffset maybeLimitOffset
            pure ap
          let toAttestation ap =
                Attestation
                  { attestationId = attestationProjectionAttestationId ap,
                    attestationSubjectProfileId = attestationProjectionSubjectProfileId ap,
                    attestationIssuerProfileId = attestationProjectionIssuerProfileId ap,
                    attestationAttestationDate = attestationProjectionAttestationDate ap,
                    attestationAccepted = attestationProjectionIsAccepted ap,
                    attestationName = attestationProjectionAttestationName ap,
                    attestationDescription = attestationProjectionAttestationDescription ap,
                    attestationImageURI = attestationProjectionAttestationImageURI ap,
                    attestationOtherMetadata =
                      maybe
                        []
                        fromAttestationOtherMetadataJson
                        (attestationProjectionOtherMetadata ap),
                    attestationTxHash = Just (attestationProjectionCreatedTxId ap),
                    attestationSlot = Just (attestationProjectionCreatedAtSlot ap),
                    attestationOutputIndex = Just (attestationProjectionCreatedOutputIndex ap)
                  }
          pure (Prelude.map (toAttestation . entityVal) rows)
      )
      pool

getAttestationsCount :: (MonadIO m, MonadReader QueryAppContext m) => Maybe F.AttestationFilter -> m Int
getAttestationsCount maybeAttestationFilter = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          cnt <- selectOne $ do
            ap <- from $ table @AttestationProjection
            applyAttestationFilter maybeAttestationFilter ap
            pure countRows
          pure (maybe 0 unValue cnt)
      )
      pool




getProfileTypeTotals :: (MonadIO m, MonadReader QueryAppContext m) => m [(ProfileType, Int)]
getProfileTypeTotals = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            pp <- from $ table @ProfileProjection
            groupBy (pp ^. ProfileProjectionProfileType)
            pure (pp ^. ProfileProjectionProfileType, countRows)
          pure [(unValue t, unValue c) | (t, c) <- rows]
      )
      pool






profileSearchFilter :: ProfileType -> Text -> F.ProfileFilter
profileSearchFilter pt q =
  F.ProfileFilter
    { C.profileFilterId = Nothing,
      C.profileFilterType = Just pt,
      C.profileFilterName = Nothing,
      C.profileFilterDescription = Nothing,
      C.profileFilterTextSearch = Just q,
      C.profileFilterRegisteredAfterSlot = Nothing
    }

attestationSearchFilter :: Text -> F.AttestationFilter
attestationSearchFilter q =
  F.AttestationFilter
    { C.attestationFilterId = Nothing,
      C.attestationFilterSubjectProfileId = Nothing,
      C.attestationFilterIssuerProfileId = Nothing,
      C.attestationFilterIsAccepted = Nothing,
      C.attestationFilterDateInterval = (Nothing, Nothing),
      C.attestationFilterTextSearch = Just q
    }




-- | Attestation text search matching id, profile ids, name, and description.
attestationMatchesSearch :: Text -> Attestation -> Bool
attestationMatchesSearch q a =
  let q' = T.toLower q
      t :: (ToJSON a) => a -> Text
      t = T.pack . stringFromJSON
   in T.isInfixOf q' (t (attestationId a))
        || T.isInfixOf q' (t (attestationSubjectProfileId a))
        || T.isInfixOf q' (t (attestationIssuerProfileId a))
        || T.isInfixOf q' (T.toLower (attestationName a))
        || T.isInfixOf q' (T.toLower (attestationDescription a))

profileToHitPractitioner :: Profile -> SearchHit
profileToHitPractitioner p =
  SearchHit
    { searchHitId = T.pack $ stringFromJSON (profileId p),
      searchHitTitle = profileName p,
      searchHitSubtitle = profileDescription p,
      searchHitBadges = ["Practitioner"],
      searchHitStatus = Nothing,
      searchHitTarget =
        SearchTarget
          { searchTargetKind = "practitioner_profile",
            searchTargetId = T.pack $ stringFromJSON (profileId p)
          }
    }

profileToHitOrganization :: Profile -> SearchHit
profileToHitOrganization p =
  SearchHit
    { searchHitId = T.pack $ stringFromJSON (profileId p),
      searchHitTitle = profileName p,
      searchHitSubtitle = profileDescription p,
      searchHitBadges = ["Organization"],
      searchHitStatus = Nothing,
      searchHitTarget =
        SearchTarget
          { searchTargetKind = "organization_profile",
            searchTargetId = T.pack $ stringFromJSON (profileId p)
          }
    }

-- | Default maximum results per search group.
searchGroupLimit :: Int
searchGroupLimit = 10

-- | Cap on rows fetched per entity in unified search, to bound memory. The @/search@
-- route has no limit/offset param, so the Step-1 pagination default never reaches this
-- path; each sub-query is capped here instead. Group totals become "up to the cap".
searchQueryLimit :: Int
searchQueryLimit = 500




attestationToHit :: Attestation -> SearchHit
attestationToHit a =
  SearchHit
    { searchHitId = T.pack $ stringFromJSON (attestationId a),
      searchHitTitle = attestationName a,
      searchHitSubtitle = attestationDescription a,
      searchHitBadges = ["Attestation"],
      searchHitStatus = Nothing,
      searchHitTarget =
        SearchTarget
          { searchTargetKind = "attestation",
            searchTargetId = T.pack $ stringFromJSON (attestationId a)
          }
    }

-- | Batch-load profile display names for a set of profile IDs. Used to enrich
-- rank and promotion search hits with human-readable names instead of raw IDs.
batchProfileNames :: (MonadIO m, MonadReader QueryAppContext m) => [ProfileRefAC] -> m (M.Map ProfileRefAC Text)
batchProfileNames [] = return M.empty
batchProfileNames pids = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            pp <- from $ table @ProfileProjection
            where_ (pp ^. ProfileProjectionProfileId `in_` valList (nub pids))
            pure (pp ^. ProfileProjectionProfileId, pp ^. ProfileProjectionProfileName)
          return $ M.fromList [(unValue pid, unValue nm) | (pid, nm) <- rows]
      )
      pool



searchProjected :: (MonadIO m, MonadReader QueryAppContext m) => Text -> m SearchResults
searchProjected q
  | T.null (T.strip q) =
      pure
        SearchResults
          { searchResultsQuery = q,
            searchResultsTotal = 0,
            searchResultsPractitioners = SearchGroup 0 [],
            searchResultsOrganizations = SearchGroup 0 [],
            searchResultsAttestations = SearchGroup 0 []
          }
  | otherwise = do
      practitionerProfiles <- getProfiles (Just (searchQueryLimit, 0)) (Just (profileSearchFilter Practitioner q)) Nothing
      organizationProfiles <- getProfiles (Just (searchQueryLimit, 0)) (Just (profileSearchFilter Organization q)) Nothing
      attestations <- getAttestations (Just (searchQueryLimit, 0)) (Just (attestationSearchFilter q)) Nothing
      let prItems = map profileToHitPractitioner practitionerProfiles
          orgItems = map profileToHitOrganization organizationProfiles
          achItems = map attestationToHit attestations
          mkGroup items =
            SearchGroup
              { searchGroupTotal = length items,
                searchGroupItems = take searchGroupLimit items
              }
          total =
            length prItems
              + length orgItems
              + length achItems
      return
        SearchResults
          { searchResultsQuery = q,
            searchResultsTotal = total,
            searchResultsPractitioners = mkGroup prItems,
            searchResultsOrganizations = mkGroup orgItems,
            searchResultsAttestations = mkGroup achItems
          }





-- ---------------------------------------------------------------------------
-- Activity feed (Option A: projected DB union)
-- ---------------------------------------------------------------------------

