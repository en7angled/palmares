{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant bracket" #-}
{-# HLINT ignore "Redundant pure" #-}
{-# HLINT ignore "Fuse on/on" #-}

module Query.Projected where

import Control.Exception (throwIO)
import Control.Monad (join)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Reader.Class
import Data.Aeson (ToJSON)
import Data.Foldable (for_)
import Data.List (foldl', maximumBy, nub, sortOn)
import Data.List qualified as L (groupBy)
import Data.Map.Strict qualified as M
import Data.Maybe
import Data.Ord (Down (..), comparing)
import Data.Sequence qualified as Seq
import Data.Set qualified as S
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Database.Esqueleto.Experimental
import Database.Esqueleto.Internal.Internal (unsafeSqlCastAs, unsafeSqlFunction)
import Database.Persist qualified as P
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Filters qualified as C
import Palmares.DomainTypes.Transfer.Filters qualified as F
import Palmares.DomainTypes.Transfer.OrderBy
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AchievementsMonthlyStatsResponse (..),
    ActivityEventDetails (..),
    ActivityEventResponse (..),
    LineageEdge (..),
    LineageGraphData (..),
    LineageNode (..),
    SearchGroup (..),
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




applyAchievementFilter :: Maybe F.AchievementFilter -> SqlExpr (Entity AchievementProjection) -> SqlQuery ()
applyAchievementFilter Nothing _ = pure ()
applyAchievementFilter (Just F.AchievementFilter {..}) ap = do
  for_ achievementFilterId (\ids -> where_ (ap ^. AchievementProjectionAchievementId `in_` valList ids))
  for_ achievementFilterAwardedToProfileId (\ids -> where_ (ap ^. AchievementProjectionAwardedToProfileId `in_` valList ids))
  for_ achievementFilterAwardedByProfileId (\ids -> where_ (ap ^. AchievementProjectionAwardedByProfileId `in_` valList ids))
  for_ achievementFilterIsAccepted (\ac -> where_ (ap ^. AchievementProjectionIsAccepted ==. val ac))
  whereDateInterval achievementFilterDateInterval (ap ^. AchievementProjectionAchievementDate)
  for_
    achievementFilterTextSearch
    ( \q ->
        let pat = likePat q
         in where_ $
              (lower_ (unsafeSqlCastAs "text" (ap ^. AchievementProjectionAchievementId)) `like` pat)
                ||. (lower_ (unsafeSqlCastAs "text" (ap ^. AchievementProjectionAwardedToProfileId)) `like` pat)
                ||. (lower_ (unsafeSqlCastAs "text" (ap ^. AchievementProjectionAwardedByProfileId)) `like` pat)
                ||. (lower_ (ap ^. AchievementProjectionAchievementName) `like` pat)
                ||. (lower_ (ap ^. AchievementProjectionAchievementDescription) `like` pat)
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



getAchievements :: (MonadIO m, MonadReader QueryAppContext m) => Maybe (C.Limit, C.Offset) -> Maybe F.AchievementFilter -> Maybe (AchievementsOrderBy, SortOrder) -> m [Achievement]
getAchievements maybeLimitOffset maybeAchievementFilter maybeOrder = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          rows <- select $ do
            ap <- from $ table @AchievementProjection
            applyAchievementFilter maybeAchievementFilter ap
            case maybeOrder of
              Nothing -> pure ()
              Just (ob, so) ->
                case ob of
                  AchievementsOrderById -> orderBy [orderByDir so (ap ^. AchievementProjectionAchievementId)]
                  AchievementsOrderByDate -> orderBy [orderByDir so (ap ^. AchievementProjectionAchievementDate)]
                  AchievementsOrderByAwardedTo -> orderBy [orderByDir so (ap ^. AchievementProjectionAwardedToProfileId)]
                  AchievementsOrderByAwardedBy -> orderBy [orderByDir so (ap ^. AchievementProjectionAwardedByProfileId)]
                  AchievementsOrderByName -> orderBy [orderByDir so (ap ^. AchievementProjectionAchievementName)]
            applyLimitOffset maybeLimitOffset
            pure ap
          let toAchievement ap =
                Achievement
                  { achievementId = achievementProjectionAchievementId ap,
                    achievementAwardedToProfileId = achievementProjectionAwardedToProfileId ap,
                    achievementAwardedByProfileId = achievementProjectionAwardedByProfileId ap,
                    achievementAchievementDate = achievementProjectionAchievementDate ap,
                    achievementAccepted = achievementProjectionIsAccepted ap,
                    achievementName = achievementProjectionAchievementName ap,
                    achievementDescription = achievementProjectionAchievementDescription ap,
                    achievementImageURI = achievementProjectionAchievementImageURI ap,
                    achievementOtherMetadata =
                      maybe
                        []
                        fromAchievementOtherMetadataJson
                        (achievementProjectionOtherMetadata ap),
                    achievementTxHash = Just (achievementProjectionCreatedTxId ap),
                    achievementSlot = Just (achievementProjectionCreatedAtSlot ap),
                    achievementOutputIndex = Just (achievementProjectionCreatedOutputIndex ap)
                  }
          pure (Prelude.map (toAchievement . entityVal) rows)
      )
      pool

getAchievementsCount :: (MonadIO m, MonadReader QueryAppContext m) => Maybe F.AchievementFilter -> m Int
getAchievementsCount maybeAchievementFilter = do
  pool <- asks pgPool
  liftIO $
    runSqlPool
      ( do
          cnt <- selectOne $ do
            ap <- from $ table @AchievementProjection
            applyAchievementFilter maybeAchievementFilter ap
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

achievementSearchFilter :: Text -> F.AchievementFilter
achievementSearchFilter q =
  F.AchievementFilter
    { C.achievementFilterId = Nothing,
      C.achievementFilterAwardedToProfileId = Nothing,
      C.achievementFilterAwardedByProfileId = Nothing,
      C.achievementFilterIsAccepted = Nothing,
      C.achievementFilterDateInterval = (Nothing, Nothing),
      C.achievementFilterTextSearch = Just q
    }




-- | Achievement text search matching id, profile ids, name, and description.
achievementMatchesSearch :: Text -> Achievement -> Bool
achievementMatchesSearch q a =
  let q' = T.toLower q
      t :: (ToJSON a) => a -> Text
      t = T.pack . stringFromJSON
   in T.isInfixOf q' (t (achievementId a))
        || T.isInfixOf q' (t (achievementAwardedToProfileId a))
        || T.isInfixOf q' (t (achievementAwardedByProfileId a))
        || T.isInfixOf q' (T.toLower (achievementName a))
        || T.isInfixOf q' (T.toLower (achievementDescription a))

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




achievementToHit :: Achievement -> SearchHit
achievementToHit a =
  SearchHit
    { searchHitId = T.pack $ stringFromJSON (achievementId a),
      searchHitTitle = achievementName a,
      searchHitSubtitle = achievementDescription a,
      searchHitBadges = ["Achievement"],
      searchHitStatus = Nothing,
      searchHitTarget =
        SearchTarget
          { searchTargetKind = "achievement",
            searchTargetId = T.pack $ stringFromJSON (achievementId a)
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
            searchResultsAchievements = SearchGroup 0 []
          }
  | otherwise = do
      practitionerProfiles <- getProfiles (Just (searchQueryLimit, 0)) (Just (profileSearchFilter Practitioner q)) Nothing
      organizationProfiles <- getProfiles (Just (searchQueryLimit, 0)) (Just (profileSearchFilter Organization q)) Nothing
      achievements <- getAchievements (Just (searchQueryLimit, 0)) (Just (achievementSearchFilter q)) Nothing
      let prItems = map profileToHitPractitioner practitionerProfiles
          orgItems = map profileToHitOrganization organizationProfiles
          achItems = map achievementToHit achievements
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
            searchResultsAchievements = mkGroup achItems
          }





-- ---------------------------------------------------------------------------
-- Activity feed (Option A: projected DB union)
-- ---------------------------------------------------------------------------

-- | Paginated activity feed built from projection tables.  Fetches recent
-- rows from profiles, promotions, ranks, achievements, and membership
-- intervals, then batch-resolves actor/target display names from
-- @profile_projection@.  Merges + sorts by timestamp descending in Haskell.
getActivityFeed ::
  (MonadIO m, MonadReader QueryAppContext m) =>
  GYSlotConfig ->
  Maybe (C.Limit, C.Offset) ->
  Maybe F.ActivityFilter ->
  m [ActivityEventResponse]
getActivityFeed slotCfg maybeLimitOffset maybeFilter = do
  pool <- asks pgPool
  let wantType et = case maybeFilter >>= C.activityFilterEventType of
        Nothing -> True
        Just t -> t == et
      actorFilter = maybeFilter >>= C.activityFilterActor
      -- `since` becomes a slot BEFORE the SQL, so the created_at_slot index is used (fix #5).
      sinceSlot = utcToSlot slotCfg . posixSecondsToUTCTime . timeToPOSIX <$> (maybeFilter >>= C.activityFilterSince)
  -- Intermediate type: event without resolved names.
  -- (eventType, actorId, targetId, createdAtSlot, title, body)
  rawEvents <-
    liftIO $
      runSqlPool
        ( do
            -- 1. Profile registrations
            profileEvts <-
              if wantType EvtProfileCreated
                then do
                  rows <- select $ do
                    pp <- from $ table @ProfileProjection
                    for_ actorFilter (\a -> where_ (pp ^. ProfileProjectionProfileId ==. val a))
                    for_ sinceSlot (\s -> where_ (pp ^. ProfileProjectionCreatedAtSlot >. val s))
                    orderBy [Database.Esqueleto.Experimental.desc (pp ^. ProfileProjectionCreatedAtSlot)]
                    Database.Esqueleto.Experimental.limit 200
                    pure pp
                  pure
                    [ ( EvtProfileCreated,
                        profileProjectionProfileId p,
                        Nothing,
                        profileProjectionCreatedAtSlot p,
                        "Profile Created" :: Text,
                        Just $ "New " <> T.toLower (T.pack (show (profileProjectionProfileType p))) <> " profile registered"
                      )
                    | Entity _ p <- rows
                    ]
                else pure []

            -- 2. Attestations
            achEvts <-
              if wantType EvtAchievementAwarded || wantType EvtAchievementAccepted
                then do
                  rows <- select $ do
                    ap_ <- from $ table @AchievementProjection
                    for_ actorFilter (\a -> where_ (ap_ ^. AchievementProjectionAwardedToProfileId ==. val a))
                    for_ sinceSlot (\s -> where_ (ap_ ^. AchievementProjectionCreatedAtSlot >. val s))
                    orderBy [Database.Esqueleto.Experimental.desc (ap_ ^. AchievementProjectionCreatedAtSlot)]
                    Database.Esqueleto.Experimental.limit 200
                    pure ap_
                  pure
                    [ ( evtType,
                        achievementProjectionAwardedToProfileId a,
                        Just (achievementProjectionAwardedByProfileId a),
                        achievementProjectionCreatedAtSlot a,
                        if achievementProjectionIsAccepted a then "Achievement Accepted" else ("Achievement Awarded" :: Text),
                        Just $ "Achievement: " <> achievementProjectionAchievementName a
                      )
                    | Entity _ a <- rows,
                      let evtType = if achievementProjectionIsAccepted a then EvtAchievementAccepted else EvtAchievementAwarded,
                      wantType evtType
                    ]
                else pure []

            pure $ profileEvts <> achEvts
        )
        pool

  -- Batch-resolve profile display names (single SQL query).
  let allPids = nub $ concatMap (\(_, actor, target, _, _, _) -> actor : maybeToList target) rawEvents
  nameMap <-
    liftIO $
      runSqlPool
        ( do
            rows <- select $ do
              pp <- from $ table @ProfileProjection
              where_ (pp ^. ProfileProjectionProfileId `in_` valList allPids)
              pure (pp ^. ProfileProjectionProfileId, pp ^. ProfileProjectionProfileName)
            pure $ M.fromList [(unValue pid, unValue name) | (pid, name) <- rows]
        )
        pool

  let lookupName pid = M.lookup pid nameMap
      toResponse (evtType, actorId, targetId, slot, title, body) =
        ActivityEventResponse
          { activityEventEventType = evtType,
            activityEventActorId = actorId,
            activityEventTargetId = targetId,
            activityEventTimestamp = timeFromPOSIX (utcTimeToPOSIXSeconds (slotToUTC slotCfg slot)),
            activityEventDetails =
              ActivityEventDetails
                { activityEventDetailsTitle = title,
                  activityEventDetailsBody = body,
                  activityEventDetailsActorName = lookupName actorId,
                  activityEventDetailsTargetName = targetId >>= lookupName
                }
          }
      sorted = sortOn (Down . activityEventTimestamp) $ map toResponse rawEvents
  pure $ C.applyLimits maybeLimitOffset sorted

