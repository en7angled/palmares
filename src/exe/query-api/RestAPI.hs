{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module RestAPI where

import Palmares.Constants (appVersion)
import Control.Lens hiding (Context)
import Control.Monad.Reader (lift)
import Data.Swagger
import Data.Text hiding (length, map)
import Palmares.DomainTypes.Core.Types
import Palmares.DomainTypes.Transfer.Types
import GeniusYield.Imports
import GeniusYield.Types hiding (description, title)
import Network.Wai
import Network.Wai.Middleware.Servant.Options (provideOptions)
import Query.Aggregates qualified as Agg
import Query.Common qualified as C
import Query.Pages qualified as Pg
import Query.Projected qualified as P
import Query.ServiceStatus (getProtocolStatusQuery, getReadyProbe)
import QueryAppMonad
import Palmares.DomainTypes.Transfer.Filters
  ( achievementFilterFromParams,
    activityFilterFromParams,
    profileFilterFromParams,
  )
import Palmares.DomainTypes.Transfer.QueryResponses
import Servant
import Servant.Swagger
import Servant.Swagger.UI
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.DomainTypes.Transfer.OrderBy
import Palmares.WebAPI.Auth
import Palmares.WebAPI.CORS
import Palmares.WebAPI.ServiceProbe
import Palmares.WebAPI.Utils (addSharedSwaggerDescriptions)

------------------------------------------------------------------------------------------------

--  Health API

------------------------------------------------------------------------------------------------

type ServiceProbeAPI = ServiceProbe Text Text

proxyServiceProbe :: Proxy ServiceProbeAPI
proxyServiceProbe = Proxy

handleReady :: QueryAppMonad (ServiceProbeStatus Text)
handleReady = getReadyProbe

serviceProbeServer :: ServerT ServiceProbeAPI QueryAppMonad
serviceProbeServer = alwaysHealthy (pack appVersion) "query-api" :<|> handleReady

------------------------------------------------------------------------------------------------

--  Profiles API

------------------------------------------------------------------------------------------------

type Profiles =
  -- Get organization profile endpoint
  ( Summary "Get Organization Profile Information"
      :> Description "Get Organization Profile Information"
      :> "organization"
      :> Capture "profile-id" ProfileRefAC
      :> Get '[JSON] OrganizationProfileResponse
  )
    :<|>
    -- Get profiles endpoint
    ( Summary "Get Profiles"
        :> Description "Get Profiles"
        :> "profiles"
        :> QueryParam' '[Optional] "limit" Int
        :> QueryParam' '[Optional] "offset" Int
        :> QueryParams "profile" ProfileRefAC
        :> QueryParam' '[Optional] "profile_type" ProfileType
        :> QueryParam' '[Optional] "q" Text
        :> QueryParam' '[Optional] "order_by" ProfilesOrderBy
        :> QueryParam' '[Optional] "sort_order" SortOrder
        :> Get '[JSON] [ProfileResponse]
    )

-- Health handlers moved to WebAPI.Health

handleGetOrganizationProfile :: ProfileRefAC -> QueryAppMonad OrganizationProfileResponse
handleGetOrganizationProfile profileRefAC =
  organizationProfileToResponse <$> P.getOrganizationProfile profileRefAC

handleGetProfiles ::
  Maybe Int ->
  Maybe Int ->
  [ProfileRefAC] ->
  Maybe ProfileType ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad [ProfileResponse]
handleGetProfiles limit offset profileRefs profileType q orderBy sortOrder = do
  let limitOffset = C.normalizeLimitOffset limit offset
  let profileFilter = Just $ profileFilterFromParams profileRefs profileType q
  let order = C.normalizeOrder orderBy sortOrder
  map profileToResponse <$> P.getProfiles limitOffset profileFilter order

profilesServer :: ServerT Profiles QueryAppMonad
profilesServer =
  handleGetOrganizationProfile
    :<|> handleGetProfiles

------------------------------------------------------------------------------------------------

--  Achievements API

------------------------------------------------------------------------------------------------

type Achievements =
  ( Summary "Get Achievements"
      :> Description "Get achievements with optional filters"
      :> "achievements"
      :> QueryParam' '[Optional] "limit" Int
      :> QueryParam' '[Optional] "offset" Int
      :> QueryParams "achievement" AchievementAC
      :> QueryParams "awarded_to" ProfileRefAC
      :> QueryParams "awarded_by" ProfileRefAC
      :> QueryParam' '[Optional] "accepted" Bool
      :> QueryParam' '[Optional] "from" GYTime
      :> QueryParam' '[Optional] "to" GYTime
      :> QueryParam' '[Optional] "q" Text
      :> QueryParam' '[Optional] "order_by" AchievementsOrderBy
      :> QueryParam' '[Optional] "sort_order" SortOrder
      :> Get '[JSON] [AchievementResponse]
  )
    :<|>
    -- Get single achievement by ID
    ( Summary "Get Achievement by ID"
        :> Description "Get a single achievement by its asset class ID"
        :> "achievement"
        :> Capture "achievement-id" AchievementAC
        :> Get '[JSON] AchievementInformationResponse
    )

handleGetAchievements ::
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
  QueryAppMonad [AchievementResponse]
handleGetAchievements limit offset achievementIds awardedToRefs awardedByRefs accepted fromTime toTime q orderBy sortOrder = do
  let limitOffset = C.normalizeLimitOffset limit offset
  let achievementFilter = Just $ achievementFilterFromParams achievementIds awardedToRefs awardedByRefs accepted fromTime toTime q
  let order = C.normalizeOrder orderBy sortOrder
  map achievementToResponse <$> P.getAchievements limitOffset achievementFilter order

handleGetAchievementById :: AchievementAC -> QueryAppMonad AchievementInformationResponse
handleGetAchievementById achId = do
  let achFilter = Just $ achievementFilterFromParams [achId] [] [] Nothing Nothing Nothing Nothing
  results <- P.getAchievements Nothing achFilter Nothing
  case results of
    (a : _) -> Agg.achievementToInformation a
    [] -> runWithQueryErrorHandling $ throwIO AchievementNotFound

achievementsServer :: ServerT Achievements QueryAppMonad
achievementsServer = handleGetAchievements :<|> handleGetAchievementById

------------------------------------------------------------------------------------------------

--  Search API

------------------------------------------------------------------------------------------------

type SearchAPI =
  Summary "Unified search"
    :> Description "Search across profiles and attestations. Query parameter q is required."
    :> "search"
    :> QueryParam' '[Required] "q" Text
    :> Get '[JSON] SearchResults

handleSearch :: Text -> QueryAppMonad SearchResults
handleSearch q = P.searchProjected q

searchServer :: ServerT SearchAPI QueryAppMonad
searchServer = handleSearch

------------------------------------------------------------------------------------------------

--  Protocol Status API

------------------------------------------------------------------------------------------------

type ProtocolStatusAPI =
  Summary "Get Protocol Status"
    :> Description "Get protocol operational status including pause state, min UTxO value, and fee configuration"
    :> "protocol-status"
    :> Get '[JSON] ProtocolStatus

handleGetProtocolStatus :: QueryAppMonad ProtocolStatus
handleGetProtocolStatus = getProtocolStatusQuery

protocolStatusServer :: ServerT ProtocolStatusAPI QueryAppMonad
protocolStatusServer = handleGetProtocolStatus

------------------------------------------------------------------------------------------------

--  Activity feed API

------------------------------------------------------------------------------------------------

type ActivityAPI =
  Summary "Activity feed"
    :> Description "Reverse-chronological activity feed across profiles and attestations."
    :> "activity"
    :> QueryParam' '[Optional] "limit" Int
    :> QueryParam' '[Optional] "offset" Int
    :> QueryParam' '[Optional] "event_type" ActivityEventType
    :> QueryParam' '[Optional] "actor" ProfileRefAC
    :> QueryParam' '[Optional] "since" GYTime
    :> Get '[JSON] [ActivityEventResponse]

handleGetActivity ::
  Maybe Int ->
  Maybe Int ->
  Maybe ActivityEventType ->
  Maybe ProfileRefAC ->
  Maybe GYTime ->
  QueryAppMonad [ActivityEventResponse]
handleGetActivity limit offset eventType actor since = do
  let limitOffset = C.normalizeLimitOffset (Just (fromMaybe 20 limit)) offset
      actFilter = activityFilterFromParams eventType actor since
  -- One slot config per request; row conversion is pure (fix #5).
  slotCfg <- requestSlotConfig
  P.getActivityFeed slotCfg limitOffset actFilter

activityServer :: ServerT ActivityAPI QueryAppMonad
activityServer = handleGetActivity

------------------------------------------------------------------------------------------------

--  Explorer pages API (§12.5)

------------------------------------------------------------------------------------------------

type PagesAPI =
  ( Summary "Achievements explorer page"
      :> Description "Paginated achievements, total, and monthly accepted/pending counts. Same query parameters as GET /achievements."
      :> "pages"
      :> "achievements"
      :> QueryParam' '[Optional] "limit" Int
      :> QueryParam' '[Optional] "offset" Int
      :> QueryParams "achievement" AchievementAC
      :> QueryParams "awarded_to" ProfileRefAC
      :> QueryParams "awarded_by" ProfileRefAC
      :> QueryParam' '[Optional] "accepted" Bool
      :> QueryParam' '[Optional] "from" GYTime
      :> QueryParam' '[Optional] "to" GYTime
      :> QueryParam' '[Optional] "q" Text
      :> QueryParam' '[Optional] "order_by" AchievementsOrderBy
      :> QueryParam' '[Optional] "sort_order" SortOrder
      :> Get '[JSON] AchievementsPageResponse
  )
    :<|> ( Summary "Profiles explorer page"
             :> Description "Paginated profiles, total, and profile-type frequency. Same query parameters as GET /profiles."
             :> "pages"
             :> "profiles"
             :> QueryParam' '[Optional] "limit" Int
             :> QueryParam' '[Optional] "offset" Int
             :> QueryParams "profile" ProfileRefAC
             :> QueryParam' '[Optional] "profile_type" ProfileType
             :> QueryParam' '[Optional] "q" Text
             :> QueryParam' '[Optional] "order_by" ProfilesOrderBy
             :> QueryParam' '[Optional] "sort_order" SortOrder
             :> Get '[JSON] ProfilesPageResponse
         )
    :<|> ( Summary "Organization explorer page"
             :> Description "Organization profiles in one page + total. Filters match GET /profiles except profile_type is always Organization. Collapses the org explorer's per-row GET /organization/{id} (N+1) into a single response."
             :> "pages"
             :> "organization-explorer"
             :> QueryParam' '[Optional] "limit" Int
             :> QueryParam' '[Optional] "offset" Int
             :> QueryParams "profile" ProfileRefAC
             :> QueryParam' '[Optional] "q" Text
             :> QueryParam' '[Optional] "order_by" ProfilesOrderBy
             :> QueryParam' '[Optional] "sort_order" SortOrder
             :> Get '[JSON] OrganizationExplorerPageResponse
         )

handleGetAchievementsPage ::
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
handleGetAchievementsPage = Pg.getAchievementsPage

handleGetProfilesPage ::
  Maybe Int ->
  Maybe Int ->
  [ProfileRefAC] ->
  Maybe ProfileType ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad ProfilesPageResponse
handleGetProfilesPage = Pg.getProfilesPage

handleGetOrganizationExplorerPage ::
  Maybe Int ->
  Maybe Int ->
  [ProfileRefAC] ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad OrganizationExplorerPageResponse
handleGetOrganizationExplorerPage = Pg.getOrganizationExplorerPage

pagesServer :: ServerT PagesAPI QueryAppMonad
pagesServer =
  handleGetAchievementsPage
    :<|> handleGetProfilesPage
    :<|> handleGetOrganizationExplorerPage

------------------------------------------------------------------------------------------------

--  Core Function API

------------------------------------------------------------------------------------------------

-- | Combined API
type CoreFunctionAPI =
  Profiles
    :<|> Achievements
    :<|> SearchAPI
    :<|> ProtocolStatusAPI
    :<|> ActivityAPI
    :<|> PagesAPI

proxyCoreFunctionAPI :: Proxy CoreFunctionAPI
proxyCoreFunctionAPI = Proxy

coreFunctionServer :: ServerT CoreFunctionAPI QueryAppMonad
coreFunctionServer =
  profilesServer
    :<|> achievementsServer
    :<|> searchServer
    :<|> protocolStatusServer
    :<|> activityServer
    :<|> pagesServer

------------------------------------------------------------------------------------------------

--  Swagger API

------------------------------------------------------------------------------------------------

type PublicAPI =
  ServiceProbeAPI
    :<|> CoreFunctionAPI

proxyPublicAPI :: Proxy PublicAPI
proxyPublicAPI = Proxy

apiSwagger :: Swagger
apiSwagger =
  toSwagger proxyPublicAPI
    & info . title .~ "Palmares Query API"
    & info . Data.Swagger.version .~ "0.1.0"
    & info . Data.Swagger.description ?~ "This is the Palmares Query API - read-only queries over the projected attestation registry (profiles, attestations, search, activity)."
    & info . license ?~ "Apache-2.0"
    & host .~ Nothing
    -- Response descriptions
    & allOperations . responses . at 400 ?~ Inline (mempty {_responseDescription = "Invalid query parameters or malformed request"})
    & allOperations . responses . at 404 ?~ Inline (mempty {_responseDescription = "Requested entity not found (profile, attestation, etc.)"})
    & allOperations . responses . at 503 ?~ Inline (mempty {_responseDescription = "Service not ready (chain-sync still syncing or protocol paused)"})
    -- Shared type descriptions
    & addSharedSwaggerDescriptions
    -- Query-API-specific type descriptions
    & definitions . at "ActivityEventType" . mapped . description ?~ "Type of activity event: ProfileCreated, AchievementAwarded, AchievementAccepted"
    -- Response type descriptions
    & definitions . at "ProfileResponse" . mapped . description ?~ "Basic profile summary with thumbnail URI derived from the on-chain image URI"
    & definitions . at "OrganizationProfileResponse" . mapped . description ?~ "Organization profile"
    & definitions . at "AchievementResponse" . mapped . description ?~ "Attestation with issuer/subject profile IDs and acceptance status"
    & definitions . at "AchievementInformationResponse" . mapped . description ?~ "Enriched attestation with full subject and issuer profile objects resolved inline"
    & definitions . at "SearchResults" . mapped . description ?~ "Unified search results grouped by category (profiles, attestations)"
    & definitions . at "AchievementsPageResponse" . mapped . description ?~ "Attestations explorer page: paginated items + total count + monthly accepted/pending stats"
    & definitions . at "ProfilesPageResponse" . mapped . description ?~ "Profiles explorer page: paginated items + total count + profile-type frequency"
    & definitions . at "OrganizationExplorerPageResponse" . mapped . description ?~ "Organization explorer page: one page of organization profiles + total (collapses the per-row org fetch)"
    & definitions . at "ActivityEventResponse" . mapped . description ?~ "Single activity feed entry with event type, actor/target IDs, timestamp, and human-readable details"

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") QueryAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwagger

------------------------------------------------------------------------------------------------

--  Combined API

------------------------------------------------------------------------------------------------

-- | Adding Basic Auth
type PrivateRestAPI =
  BasicAuth "user-realm" AuthUser :> CoreFunctionAPI

proxyPrivateRestAPI :: Proxy PrivateRestAPI
proxyPrivateRestAPI = Proxy

privateRestServer :: ServerT PrivateRestAPI QueryAppMonad
privateRestServer = const coreFunctionServer

-- | Adding Swagger UI on top of Private Rest API
type FullAPI =
  SwaggerSchemaUI "swagger-ui" "swagger-api.json"
    :<|> ServiceProbeAPI
    :<|> PrivateRestAPI

proxyFullAPI :: Proxy FullAPI
proxyFullAPI = Proxy

fullServer :: ServerT FullAPI QueryAppMonad
fullServer = swaggerServer :<|> serviceProbeServer :<|> privateRestServer

------------------------------------------------------------------------------------------------

-- | Servant Application

------------------------------------------------------------------------------------------------

mkWebApp :: CorsConfig -> QueryAppContext -> Application
mkWebApp corsCfg ctx =
  mkCorsMiddleware corsCfg $
    provideOptions proxyPublicAPI $
      serveWithContext proxyFullAPI basicCtx hoistedServer
  where
    basicCtx = basicAuthServerContext (authContext ctx)
    hoistedServer = hoistServerWithContext proxyFullAPI proxyBasicAuthContext (runAppMonad ctx) fullServer
