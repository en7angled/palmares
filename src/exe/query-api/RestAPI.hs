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
import Palmares.DomainTypes.Core.Types
  ( AnchorStatus,
    DRepId,
    DRepStatus,
    DRepUpdateKind,
    GovActionId (..),
    GovActionState,
    GovActionType,
    VoterRole (..),
    drepIdHex,
  )
import Palmares.DomainTypes.Transfer.Filters
  ( DRepFilter (..),
    GovActionFilter (..),
    emptyDRepFilter,
    emptyGovActionFilter,
  )
import Palmares.DomainTypes.Transfer.OrderBy
  ( DRepsOrderBy (..),
    DelegatorsOrderBy (..),
    GovActionsOrderBy (..),
    SortOrder (..),
  )
import Palmares.DomainTypes.Transfer.QueryResponses
  ( DRepDetailResponse (..),
    DRepMetrics (..),
    DRepSummary,
    DRepUpdateRow,
    DelegatorRow,
    EpochPowerPoint,
    GovActionAnchorContent,
    GovActionDetailResponse (..),
    GovActionSummary,
    ParamChangeRow (..),
    ProposerSummary,
    StatusResponse (..),
    TreasuryWithdrawalRow,
    VoteTally (..),
  )
import Palmares.Metrics.Catalog (MetricFormula, resolvedMetricCatalog, retentionWindowEpochs)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.CSV (CSV)
import Data.Text qualified as T
import Palmares.WebAPI.Envelope (ErrorCode (..), Page (..), errorCodeFromText, errorCodeToHttpStatus)
import Palmares.WebAPI.Errors (mkServantErr)
import Query.Common
  ( PageBounds (..),
    boundsFor,
    checkRanges,
    epochSeriesBounds,
    jsonBounds,
    normalizeLimitOffset,
    normalizeQ,
  )
import Query.Csv ()
import Data.Text.Read qualified as TRead
import Database.Persist.Sql (SqlPersistT)
import Query.Thresholds (drepParamChangeThreshold, paramGroupColumns)
import Query.Gov
  ( anchorContentQuery,
    govActionAnchorQuery,
    govActionByIdQuery,
    listTallies,
    listWithdrawals,
    paramChangeColumns,
    proposerQuery,
    resolveGovAction,
    thresholdValueAt,
    delegatorOrderColumn,
    delegatorStatsQuery,
    drepMetricsQuery,
    drepSummaryByIdQuery,
    listDRepUpdates,
    listDReps,
    listDelegators,
    listEpochPower,
    listGovActions,
    resolveDRepHex,
  )
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

--  The DRep profile

------------------------------------------------------------------------------------------------

-- | The composite, on two paths with ONE handler and ONE response type.
--
-- @/pages/drep/{id}@ is the canonical path a screen renders; @/drep/{id}@ is the alias for a
-- consumer who does not want page framing. Deliberately not two DTOs: two response types for one
-- screen is how a field gets fixed in one and forgotten in the other.
--
-- @votes@ and @timeline@ are absent until GET /votes and GET /activity define their row types,
-- for exactly that reason -- inventing them here would be the duplication the paragraph above
-- warns against. Each arrives later as a new optional field, a minor Swagger bump.
type DRepDetailAPI =
  Summary "DRep profile"
    :> Description
         "One DRep's whole public record in a single request: identity and status, every published \
         \metric with the formula ids that produced them, voting power epoch by epoch, how the \
         \delegator base moved, the top delegators, the certificate history, and the CIP-119 \
         \metadata -- the last only when its anchor hash verified, because a document that did not \
         \match its on-chain commitment is not this DRep's statement about itself."
    :> "drep"
    :> Capture "drep-id" DRepId
    :> Get '[JSON] DRepDetailResponse

type DRepPageAPI =
  Summary "DRep profile (canonical page path)"
    :> Description "Identical to GET /drep/{drep-id}: same handler, same response."
    :> "pages"
    :> "drep"
    :> Capture "drep-id" DRepId
    :> Get '[JSON] DRepDetailResponse

type DRepPowerAPI =
  Summary "A DRep's voting power, epoch by epoch"
    :> Description
         "Gaps are real and are not filled: an epoch missing from the series is an epoch the \
         \ledger's stake distribution did not include this DRep, and zero-filling it would turn an \
         \absence into a measurement. No CSV -- 200 epoch rows is one JSON page -- and no rank, \
         \which would be a window function over the whole distribution per epoch."
    :> "drep"
    :> Capture "drep-id" DRepId
    :> "power"
    :> QueryParam "limit" Int
    :> QueryParam "from_epoch" Int
    :> QueryParam "to_epoch" Int
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page EpochPowerPoint)

type DRepDelegatorsAPI =
  Summary "A DRep's delegators"
    :> Description
         "`lovelace` is the stake the ledger counted at the latest snapshot, so it is null for a \
         \delegation made this epoch -- real, and not yet weighed. `is_current` is false for a \
         \delegation since superseded or whose stake account closed; `is_current=false` includes \
         \those, which is what makes the list a history rather than a snapshot."
    :> "drep"
    :> Capture "drep-id" DRepId
    :> "delegators"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParam "is_current" Bool
    :> QueryParam "min_lovelace" Int64
    :> QueryParam "order_by" DelegatorsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page DelegatorRow)

type DRepUpdatesAPI =
  Summary "A DRep's certificate history"
    :> Description
         "`kind` comes from drep_registration.deposit and nowhere else, because that is the only \
         \place db-sync records it: a positive deposit is a registration, a negative one a \
         \retirement, and null a metadata update."
    :> "drep"
    :> Capture "drep-id" DRepId
    :> "updates"
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "kind" DRepUpdateKind
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page DRepUpdateRow)

-- | Resolve a captured id to the internal row id, or refuse.
--
-- A 'Nothing' from 'drepIdHex' here is a 404 and not a 400: the capture already rejected anything
-- malformed as @invalid_drep_id@, so what reaches this point is a well-formed identifier that is
-- not a DRep credential -- one of the two reserved ledger options, for instance.
resolveDRep :: DRepId -> QueryAppMonad Int64
resolveDRep did = do
  hex <- maybe (throwApi DrepNotFound) pure (drepIdHex did)
  mid <- runRead (resolveDRepHex hex)
  maybe (throwApi DrepNotFound) pure mid

handleGetDRepDetail :: DRepId -> QueryAppMonad DRepDetailResponse
handleGetDRepDetail did = do
  dhid <- resolveDRep did
  -- ONE runRead, so the whole page is one RepeatableRead snapshot: a composite assembled from
  -- several transactions can show metrics from one moment beside a delegator list from another.
  r <- runRead $ do
    ms <- drepSummaryByIdQuery dhid
    mm <- drepMetricsQuery dhid
    power <- listEpochPower dhid Nothing Nothing Asc 200
    -- The stats are measured at the SAME epoch as the metrics block, from the metrics block's
    -- own as_of_epoch, so the page cannot show a retention rate from one epoch beside a
    -- participation rate from another.
    mstats <- case mm of
      Nothing -> pure Nothing
      Just m -> delegatorStatsQuery dhid (drepMetricsAsOfEpoch m) retentionWindowEpochs
    tops <- listDelegators dhid True Nothing (delegatorOrderColumn DelegatorsOrderByLovelace, Desc) (10, 0)
    ups <- listDRepUpdates dhid [] Desc (50, 0)
    anchor <- anchorContentQuery dhid
    pure $
      DRepDetailResponse
        <$> ms
        <*> mm
        <*> Just power
        <*> mstats
        <*> Just (pageItems tops)
        <*> Just (pageItems ups)
        <*> Just anchor
  maybe (throwApi DrepNotFound) pure r

handleGetDRepPower ::
  DRepId -> Maybe Int -> Maybe Int -> Maybe Int -> Maybe SortOrder -> QueryAppMonad (Page EpochPowerPoint)
handleGetDRepPower did limit fromEpoch toEpoch sortOrder = do
  dhid <- resolveDRep did
  _ <- either throwApi pure (checkRanges Nothing Nothing fromEpoch toEpoch)
  (lim, off) <- either throwApi pure (normalizeLimitOffset epochSeriesBounds limit Nothing)
  items <- runRead (listEpochPower dhid fromEpoch toEpoch (fromMaybe Asc sortOrder) lim)
  -- total = the number of points returned: the series is at most 200 rows and a second COUNT
  -- query over it would cost as much as the page.
  pure (Page items (Just (length items)) lim off Nothing)

handleGetDRepDelegators ::
  DRepId ->
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  Maybe Bool ->
  Maybe Int64 ->
  Maybe DelegatorsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page DelegatorRow)
handleGetDRepDelegators did accept limit offset isCurrent minLovelace orderBy sortOrder = do
  dhid <- resolveDRep did
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  runRead $
    listDelegators
      dhid
      (fromMaybe True isCurrent)
      minLovelace
      (delegatorOrderColumn (fromMaybe DelegatorsOrderByLovelace orderBy), fromMaybe Desc sortOrder)
      bounds

handleGetDRepUpdates ::
  DRepId -> Maybe Int -> Maybe Int -> [DRepUpdateKind] -> Maybe SortOrder -> QueryAppMonad (Page DRepUpdateRow)
handleGetDRepUpdates did limit offset kinds sortOrder = do
  dhid <- resolveDRep did
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  runRead (listDRepUpdates dhid (map jsonTag kinds) (fromMaybe Desc sortOrder) bounds)

------------------------------------------------------------------------------------------------

--  Governance actions

------------------------------------------------------------------------------------------------

type GovActionsAPI =
  Summary "Governance actions"
    :> Description
         "Every governance action ever proposed, with its lifecycle. There is no default state \
         \filter, unlike /dreps: an expired action is still part of the record, and hiding 103 of \
         \preprod's 131 proposals by default would hide the history this registry exists to \
         \publish. `state` is single-valued and is a READING of the four lifecycle epochs in a \
         \fixed order, so all four travel beside it; `last_votable_epoch`, not `state`, is the \
         \authority on whether a vote is still possible. `title` and `abstract` come from CIP-108 \
         \metadata and are null for most actions -- measured, 7 of 131 on preprod have it fetched."
    :> "gov-actions"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "type" GovActionType
    :> QueryParams "state" GovActionState
    :> QueryParams "anchor_status" AnchorStatus
    :> QueryParam "proposed_from" UTCTime
    :> QueryParam "proposed_to" UTCTime
    :> QueryParam "expires_before_epoch" Int
    :> QueryParam "expires_after_epoch" Int
    :> QueryParam "proposer_stake_address" Text
    :> QueryParam "min_treasury_amount" Int64
    :> QueryParam "max_treasury_amount" Int64
    :> QueryParam "q" Text
    :> QueryParam "order_by" GovActionsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page GovActionSummary)

handleGetGovActions ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [GovActionType] ->
  [GovActionState] ->
  [AnchorStatus] ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe Int ->
  Maybe Int ->
  Maybe Text ->
  Maybe Int64 ->
  Maybe Int64 ->
  Maybe Text ->
  Maybe GovActionsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page GovActionSummary)
handleGetGovActions accept limit offset types states anchorStatus pFrom pTo expBefore expAfter proposer minT maxT q orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  _ <- either throwApi pure (checkRanges pFrom pTo expAfter expBefore)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptyGovActionFilter
          { govActionFilterTypes = types,
            govActionFilterStates = states,
            govActionFilterAnchorStatus = anchorStatus,
            govActionFilterProposedFrom = pFrom,
            govActionFilterProposedTo = pTo,
            govActionFilterExpiresBeforeEpoch = expBefore,
            govActionFilterExpiresAfterEpoch = expAfter,
            govActionFilterProposerStakeAddress = proposer,
            govActionFilterMinTreasuryAmount = minT,
            govActionFilterMaxTreasuryAmount = maxT,
            govActionFilterQ = q'
          }
  runRead
    ( listGovActions
        filt
        (fromMaybe GovActionsOrderByProposedAt orderBy, fromMaybe Desc sortOrder)
        bounds
    )

govActionsServer :: ServerT GovActionsAPI QueryAppMonad
govActionsServer = handleGetGovActions

------------------------------------------------------------------------------------------------

--  The governance action page

------------------------------------------------------------------------------------------------

type GovActionDetailAPI =
  Summary "Governance action"
    :> Description
         "One action's whole record: its lifecycle, the tally per role that voted, the threshold \
         \each tally is measured against, the payments a treasury withdrawal would make, the \
         \parameters a parameter change would change, its proposer's track record, and its CIP-108 \
         \metadata -- the last only when the anchor hash verified. `basis` on every tally is \
         \`cast_votes_only`: the ratio is over the votes ACTUALLY CAST, while the ledger compares \
         \against total active voting power, so the ratio is an observation and never a prediction. \
         \`lifecycle` is the authoritative outcome. \
         \Both id forms are accepted in the path, but the canonical `<tx_hash>#<index>` contains a \
         \`#`, which a URL treats as a fragment delimiter -- it must be sent percent-encoded as \
         \`%23`. The CIP-129 `bech32` form that /gov-actions returns has no such character and is \
         \the one to put in a link."
    :> "gov-action"
    :> Capture "gov-action-id" GovActionId
    :> Get '[JSON] GovActionDetailResponse

type GovActionPageAPI =
  Summary "Governance action (canonical page path)"
    :> Description "Identical to GET /gov-action/{gov-action-id}: same handler, same response."
    :> "pages"
    :> "gov-action"
    :> Capture "gov-action-id" GovActionId
    :> Get '[JSON] GovActionDetailResponse

handleGetGovActionDetail :: GovActionId -> QueryAppMonad GovActionDetailResponse
handleGetGovActionDetail (GovActionId gid) = do
  (txHex, ix) <- maybe (throwApi InvalidGovActionId) pure (splitActionId gid)
  r <- runRead $ do
    mid <- resolveGovAction txHex ix
    case mid of
      Nothing -> pure Nothing
      Just gaid -> do
        maction <- govActionByIdQuery gaid
        tallies <- listTallies gaid
        withdrawals <- listWithdrawals gaid
        touched <- paramChangeColumns gaid
        proposer <- proposerQuery gaid
        anchor <- govActionAnchorQuery gaid
        tallies' <- fillParamChangeThreshold touched tallies
        pure $
          (\action ->
             GovActionDetailResponse
               { govActionDetailAction = action,
                 govActionDetailTallies = tallies',
                 govActionDetailWithdrawals = withdrawals,
                 govActionDetailParamChanges =
                   [ParamChangeRow c (lookup c paramGroupColumns) | c <- touched],
                 govActionDetailProposer = proposer,
                 govActionDetailAnchorContent = anchor
               })
            <$> maction
  maybe (throwApi GovActionNotFound) pure r

-- | Fill the one threshold @palmares.vote_tally@ deliberately leaves NULL.
--
-- A ParameterChange's DRep threshold is the MAXIMUM over the CIP-1694 groups the proposal touches,
-- which is a property of the proposal and not of its type — so the view cannot resolve it from the
-- static map and says so in its own comment. Query.Thresholds builds the expression from a closed
-- column table and this evaluates it at the tally's epoch, echoing the expression as
-- `threshold_param` so the number stays traceable.
--
-- Only the DRep tally, and only when the view left it empty: an SPO's security-group threshold is
-- a single column the map already resolved.
fillParamChangeThreshold :: [Text] -> [VoteTally] -> SqlPersistT IO [VoteTally]
fillParamChangeThreshold touched = mapM fill
  where
    fill t
      | voteTallyRole t == DRep,
        voteTallyThresholdParam t == Nothing,
        Just expr <- drepParamChangeThreshold touched = do
          v <- thresholdValueAt expr (voteTallyEpoch t)
          pure t {voteTallyThreshold = v, voteTallyThresholdParam = Just expr}
      | otherwise = pure t

-- | Split a canonical governance action id. The capture already normalised it to this shape.
splitActionId :: Text -> Maybe (Text, Int)
splitActionId gid = case T.splitOn "#" gid of
  [h, i] | Right (n, "") <- TRead.decimal i -> Just (h, n)
  _ -> Nothing

------------------------------------------------------------------------------------------------

--  Core Function API

------------------------------------------------------------------------------------------------

-- | Every governance route family. One alternative per family; later tasks append.
type CoreFunctionAPI =
  StatusAPI
    :<|> MetricsFormulasAPI
    :<|> DRepsAPI
    :<|> DRepDetailAPI
    :<|> DRepPageAPI
    :<|> DRepPowerAPI
    :<|> DRepDelegatorsAPI
    :<|> DRepUpdatesAPI
    :<|> GovActionsAPI
    :<|> GovActionDetailAPI
    :<|> GovActionPageAPI

coreFunctionServer :: ServerT CoreFunctionAPI QueryAppMonad
-- Spelled out flat rather than grouped into a drepProfileServer: `:<|>` is right-associative,
-- so a grouped sub-server's own nesting would not match this chain's once another family is
-- appended after it. One handler per line, in the type's order.
coreFunctionServer =
  statusServer
    :<|> metricsFormulasServer
    :<|> drepsServer
    :<|> handleGetDRepDetail
    :<|> handleGetDRepDetail
    :<|> handleGetDRepPower
    :<|> handleGetDRepDelegators
    :<|> handleGetDRepUpdates
    :<|> govActionsServer
    :<|> handleGetGovActionDetail
    :<|> handleGetGovActionDetail

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
        serveWithContext proxyFullAPI (palmaresErrorFormatters :. EmptyContext) hoistedServer
  where
    hoistedServer =
      hoistServerWithContext
        proxyFullAPI
        (Proxy :: Proxy '[ErrorFormatters])
        (runAppMonad ctx)
        fullServer

-- | Make servant's OWN 400s carry the documented @{code, message}@ body.
--
-- Without this, a capture or query-parameter that fails to parse never reaches a handler: servant
-- builds its own response out of the @String@ the parser returned and serves it as plain text.
-- Measured: a DRep id with a broken bech32 checksum came back as @400 Error parsing ...@, which
-- no client could match on, next to our own 400s which carry a @code@.
--
-- Every @parseUrlPiece@ in this codebase returns the error CODE as that string, which is what
-- makes the round trip work: @invalid_drep_id@ goes out of the parser and comes back in here as
-- 'InvalidDrepId'. Anything unrecognised becomes @invalid_parameter@, which is true of it.
palmaresErrorFormatters :: ErrorFormatters
palmaresErrorFormatters =
  defaultErrorFormatters
    { -- urlParseErrorFormatter covers a failing Capture AND a failing QueryParam: servant has one
      -- hook for both, which is why there is no queryParseErrorFormatter to set.
      urlParseErrorFormatter = fromParserMessage,
      headerParseErrorFormatter = fromParserMessage
    }
  where
    fromParserMessage _ _ msg =
      let code = errorCodeFromText (T.pack msg)
       in mkServantErr (errorCodeToHttpStatus code) code
