-- | Page-shaped aggregate queries (backend-api-requirements §12): compose existing
-- projected @get*@ calls and enrich with nested profile maps.
module Query.Aggregates
  ( lookupProfileTypeProjected,
    attestationToInformation,
  )
where

import Control.Exception (throwIO)
import Database.Persist (Entity (..))
import Database.Persist.Sql (SqlPersistT)
import Database.Persist qualified as P
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Filters qualified as F
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AttestationInformationResponse,
    attestationInformationToResponse,
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



-- | Resolve an attestation's issued-to and issued-by profiles (which can be
-- either practitioners or organizations) and build an enriched response.
attestationToInformation :: Attestation -> QueryAppMonad AttestationInformationResponse
attestationToInformation a = do
  let mkFilter ref =
        Just $ F.ProfileFilter (Just [ref]) Nothing Nothing Nothing Nothing Nothing
      toFilter = mkFilter (attestationSubjectProfileId a)
      byFilter = mkFilter (attestationIssuerProfileId a)
  subjectProfiles <- P.getProfiles Nothing toFilter Nothing
  issuerProfiles <- P.getProfiles Nothing byFilter Nothing
  case (subjectProfiles, issuerProfiles) of
    (toProf : _, byProf : _) -> return $ attestationInformationToResponse toProf byProf a
    _ -> runWithQueryErrorHandling $ throwIO ProfileNotFound







