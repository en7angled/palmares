{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- | The public governance read API.
--
-- __No @BasicAuth@ layer and no @WebAPI.Auth@ import.__ This API is public by design: it
-- publishes what is already on a public chain, and putting a shared credential in front of it
-- would protect nothing while making every consumer ask for one. Rate limiting belongs to the
-- BFF in front of it, where a per-client identity exists.
--
-- 'CoreFunctionAPI' grows one alternative per route family. It is written as a single type
-- synonym so that adding a family is one line here and one line in 'coreFunctionServer', and so
-- that the Swagger document and the served routes cannot drift apart — both are derived from the
-- same type.
--
-- The inherited profile/attestation/search/activity/pages families are __gone__, not disabled:
-- they served the Belt System's projections, and Plan B rebuilds the attestation surface over
-- the attestation schema rather than over those tables. Their query modules remain on disk,
-- comment-prefixed in the cabal manifest, which is this repo's convention for \"extracted, not
-- yet re-landed\".
module RestAPI where

import Control.Lens hiding (Context)
import Data.Proxy (Proxy (..))
-- `hiding (Header)`: Data.Swagger has its own Header type and servant's is the one a route
-- means. The alternative is a qualified import of every lens used in apiSwagger.
import Data.Swagger hiding (Header)
import Data.Text (Text)
import Network.Wai (Application)
import Network.Wai.Middleware.Servant.Options (provideOptions)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types (AnchorStatus, DRepStatus, GovActionId)
import Palmares.DomainTypes.Transfer.Filters (DRepFilter (..), emptyDRepFilter)
import Palmares.DomainTypes.Transfer.OrderBy (DRepsOrderBy (..), SortOrder (..))
import Palmares.DomainTypes.Transfer.QueryResponses (DRepSummary, StatusResponse (..))
import Palmares.Metrics.Catalog (MetricFormula, resolvedMetricCatalog)
import Palmares.WebAPI.CSV (CSV)
import Palmares.WebAPI.Envelope (Page)
import Query.Common (boundsFor, checkRanges, normalizeLimitOffset, normalizeQ)
import Query.Csv ()
import Query.Gov (listDReps)
import Palmares.WebAPI.CORS (CorsConfig, mkCorsMiddleware)
import Palmares.WebAPI.ServiceProbe (ServiceProbe, ServiceProbeStatus)
import Query.Gov (Freshness, freshnessMiddleware)
import Query.ServiceStatus (getHealthProbe, getReadyProbe, getStatusQuery)
import QueryAppMonad (QueryAppContext (..), QueryAppMonad, runAppMonad, runRead, throwApi)
import Servant
import Servant.Swagger
import Servant.Swagger.UI

------------------------------------------------------------------------------------------------

--  Probes

------------------------------------------------------------------------------------------------

type ServiceProbeAPI = ServiceProbe Text Text

serviceProbeServer :: ServerT ServiceProbeAPI QueryAppMonad
serviceProbeServer = getHealthProbe :<|> getReadyProbe

------------------------------------------------------------------------------------------------

--  Status

------------------------------------------------------------------------------------------------

type StatusAPI =
  Summary "Service and chain status"
    :> Description
         "What this instance serves, how far behind the chain its index is, and the protocol \
         \parameters its published numbers mean something against. `governance.is_ready` is the \
         \same verdict /ready gives, so a client needs one request rather than two that can \
         \disagree."
    :> "status"
    :> Get '[JSON] StatusResponse

statusServer :: ServerT StatusAPI QueryAppMonad
statusServer = getStatusQuery

------------------------------------------------------------------------------------------------

--  Metric formulas

------------------------------------------------------------------------------------------------

type MetricsFormulasAPI =
  Summary "Published metric formulas"
    :> Description
         "Every number this API publishes carries the id of the formula that produced it, and this \
         \endpoint resolves those ids: what the formula means, what its denominator counts, when it \
         \is null rather than zero, which db-sync tables it reads, its edge cases, and - for the six \
         \that have one - the exact SQL statement the server executes, inlined. Those statements \
         \are read out of the same embed the query path runs, so the published formula and the \
         \served number cannot disagree."
    :> "metrics"
    :> "formulas"
    :> Get '[JSON] [MetricFormula]

-- | Serve the catalog resolved at boot.
--
-- 'either error id' is unreachable: Main checks 'resolvedMetricCatalog' and dies on a Left before
-- anything starts listening, so by the time a request arrives the catalog has already parsed and
-- every @sql_file@ has resolved.
metricsFormulasServer :: ServerT MetricsFormulasAPI QueryAppMonad
metricsFormulasServer = pure (either error id resolvedMetricCatalog)

------------------------------------------------------------------------------------------------

--  DReps

------------------------------------------------------------------------------------------------

-- | @GET \/dreps@ — the delegation-discovery list.
--
-- @Header "Accept" Text@ is load-bearing rather than informational: servant resolves content
-- negotiation inside the @Verb@ server instance and never tells the handler which type it chose,
-- so reading the header is the only way a CSV request can get its own (much higher) page ceiling.
--
-- Repeatable parameters are OR within a parameter and AND across parameters, and an EMPTY list is
-- no filter rather than "match nothing".
type DRepsAPI =
  Summary "DReps"
    :> Description
         "Registered delegate representatives with their track record: participation, rationale \
         \coverage, vote latency, voting power, delegator count and age. Default ordering is \
         \voting_power descending, because this list is what a delegator chooses from. Statuses \
         \default to the two registered ones (active and inactive) -- preprod has 511 retired \
         \DReps against 294 registered, so including them by default would make the first page \
         \mostly useless; ask for them with status=retired. The two reserved ledger options \
         \(drep_always_abstain, drep_always_no_confidence) are never listed: they hold stake but \
         \no credential, and are published by /drep-power instead."
    :> "dreps"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "status" DRepStatus
    :> QueryParams "anchor_status" AnchorStatus
    :> QueryParam "has_script" Bool
    :> QueryParam "min_voting_power" Int64
    :> QueryParam "max_voting_power" Int64
    :> QueryParam "min_delegators" Int
    :> QueryParam "min_participation_rate" Double
    :> QueryParam "min_rationale_rate" Double
    :> QueryParam "registered_before" UTCTime
    :> QueryParam "registered_after" UTCTime
    :> QueryParam "min_age_days" Int
    :> QueryParam "voted_on" GovActionId
    :> QueryParam "not_voted_on" GovActionId
    :> QueryParam "language" Text
    :> QueryParam "active_in_epoch" Int
    :> QueryParam "q" Text
    :> QueryParam "order_by" DRepsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page DRepSummary)

handleGetDReps ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [DRepStatus] ->
  [AnchorStatus] ->
  Maybe Bool ->
  Maybe Int64 ->
  Maybe Int64 ->
  Maybe Int ->
  Maybe Double ->
  Maybe Double ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe Int ->
  Maybe GovActionId ->
  Maybe GovActionId ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  Maybe DRepsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page DRepSummary)
handleGetDReps accept limit offset status anchorStatus hasScript minPower maxPower minDelegators minPart minRat regBefore regAfter minAge votedOn notVotedOn lang activeEpoch q orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  _ <- either throwApi pure (checkRanges regAfter regBefore Nothing Nothing)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptyDRepFilter
          { drepFilterStatus = status,
            drepFilterAnchorStatus = anchorStatus,
            drepFilterHasScript = hasScript,
            drepFilterMinVotingPower = minPower,
            drepFilterMaxVotingPower = maxPower,
            drepFilterMinDelegators = minDelegators,
            drepFilterMinParticipationRate = minPart,
            drepFilterMinRationaleRate = minRat,
            drepFilterRegisteredBefore = regBefore,
            drepFilterRegisteredAfter = regAfter,
            drepFilterMinAgeDays = minAge,
            drepFilterVotedOn = votedOn,
            drepFilterNotVotedOn = notVotedOn,
            drepFilterLanguage = lang,
            drepFilterActiveInEpoch = activeEpoch,
            drepFilterQ = q'
          }
  runRead (listDReps filt (fromMaybe DRepsOrderByVotingPower orderBy, fromMaybe Desc sortOrder) bounds)

drepsServer :: ServerT DRepsAPI QueryAppMonad
drepsServer = handleGetDReps

------------------------------------------------------------------------------------------------

--  Core Function API

------------------------------------------------------------------------------------------------

-- | Every governance route family. One alternative per family; later tasks append.
type CoreFunctionAPI =
  StatusAPI
    :<|> MetricsFormulasAPI
    :<|> DRepsAPI

coreFunctionServer :: ServerT CoreFunctionAPI QueryAppMonad
coreFunctionServer =
  statusServer
    :<|> metricsFormulasServer
    :<|> drepsServer

------------------------------------------------------------------------------------------------

--  Swagger

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
    & info . Data.Swagger.description
      ?~ "Read-only queries over the Cardano governance record: DReps, governance actions, votes, \
         \delegations, the constitutional committee and treasury withdrawals. Every row comes from \
         \a view over cardano-db-sync — there is no projection table and no second derivation — and \
         \every published metric carries the id of the formula that produced it, resolvable at \
         \/metrics/formulas."
    & info . license ?~ "Apache-2.0"
    & host .~ Nothing
    & allOperations . responses . at 400
      ?~ Inline (mempty {_responseDescription = "Invalid query parameters; the body carries a machine-readable `code`"})
    & allOperations . responses . at 404
      ?~ Inline (mempty {_responseDescription = "Well-formed request naming something that does not exist"})
    & allOperations . responses . at 503
      ?~ Inline (mempty {_responseDescription = "Index not ready: too far behind, no ledger state, or the wrong network"})
    & definitions . at "SyncStatus" . mapped . description
      ?~ "How far behind the chain this index is. `lag_seconds` is measured from the tip block's \
         \time; `is_ready` is /ready's own verdict."
    & definitions . at "EpochParamsSummary" . mapped . description
      ?~ "The protocol parameters a client needs to audit a published tally. Threshold lists are \
         \(name, value) pairs under db-sync's own column names, so any of them can be looked up \
         \in palmares.thresholds. `gov_action_lifetime` is the parameter, not the voting window: \
         \the ledger sets expiration = proposed_epoch + lifetime + 1."
    & definitions . at "StatusResponse" . mapped . description
      ?~ "Service identity, chain freshness and protocol parameters in one request."
    & definitions . at "MetricFormula" . mapped . description
      ?~ "One published formula. `sql` is the statement the server actually executes, inlined \
         \from the same embed the query path reads, so the documented formula cannot drift \
         \from the served number. Exactly one of `sql_file` and `sql_object` is set, so every \
         \formula_id resolves to something a reader can go and look at. `params` names the \
         \positional placeholders in bind order."

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") QueryAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwagger

------------------------------------------------------------------------------------------------

--  Application

------------------------------------------------------------------------------------------------

type FullAPI =
  SwaggerSchemaUI "swagger-ui" "swagger-api.json"
    :<|> ServiceProbeAPI
    :<|> CoreFunctionAPI

proxyFullAPI :: Proxy FullAPI
proxyFullAPI = Proxy

fullServer :: ServerT FullAPI QueryAppMonad
fullServer = swaggerServer :<|> serviceProbeServer :<|> coreFunctionServer

-- | The served application.
--
-- 'freshnessMiddleware' is applied INSIDE the CORS middleware so the chain-point headers are
-- present on the response that CORS then decides to expose; the other way round and the exposed
-- header list would name headers that are not there yet.
mkWebApp :: CorsConfig -> IO (Maybe Freshness) -> QueryAppContext -> Application
mkWebApp corsCfg readFresh ctx =
  mkCorsMiddleware corsCfg $
    freshnessMiddleware readFresh $
      provideOptions proxyPublicAPI $
        serve proxyFullAPI hoistedServer
  where
    hoistedServer = hoistServer proxyFullAPI (runAppMonad ctx) fullServer
