-- | Page-shaped aggregate queries (backend-api-requirements §12): compose existing
-- projected @get*@ calls and enrich with nested profile maps.
module Query.Aggregates
  ( lookupProfileTypeProjected,
    achievementToInformation,
  )
where

import Control.Exception (throwIO)
import Database.Persist (Entity (..))
import Database.Persist.Sql (SqlPersistT)
import Database.Persist qualified as P
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Filters qualified as F
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AchievementInformationResponse,
    achievementInformationToResponse,
  )
import Query.Projected qualified as P
import QueryAppMonad (QueryAppMonad, runWithQueryErrorHandling)
import Palmares.Storage
import Palmares.TxBuilding.Exceptions (TxBuildingException (ProfileNotFound))



lookupProfileTypeProjected ::
  ProfileRefAC ->
  SqlPersistT IO (Maybe ProfileType)
lookupProfileTypeProjected pid = do
  m <- P.getBy (UniqueProfileProjection pid)
  return $ case m of
    Nothing -> Nothing
    Just (Entity _ row) -> Just (profileProjectionProfileType row)



-- | Resolve an achievement's awarded-to and awarded-by profiles (which can be
-- either practitioners or organizations) and build an enriched response.
achievementToInformation :: Achievement -> QueryAppMonad AchievementInformationResponse
achievementToInformation a = do
  let mkFilter ref =
        Just $ F.ProfileFilter (Just [ref]) Nothing Nothing Nothing Nothing Nothing
      toFilter = mkFilter (achievementAwardedToProfileId a)
      byFilter = mkFilter (achievementAwardedByProfileId a)
  awardedToProfiles <- P.getProfiles Nothing toFilter Nothing
  awardedByProfiles <- P.getProfiles Nothing byFilter Nothing
  case (awardedToProfiles, awardedByProfiles) of
    (toProf : _, byProf : _) -> return $ achievementInformationToResponse toProf byProf a
    _ -> runWithQueryErrorHandling $ throwIO ProfileNotFound







