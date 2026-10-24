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
-- `hiding (Header)`: Data.Swagger has its own Header type and servant's is the one a route
-- means. The alternative is a qualified import of every lens used in apiSwagger.
import Data.Swagger hiding (Header)
import Data.Swagger.Declare (execDeclare)
import Data.Text (Text)
import Network.Wai.Middleware.Servant.Options (provideOptions)
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types
  ( ActivityEventType,
    ActivitySource,
    AnchorStatus,
    AttestationAC,
    AttestationType,
    DRepId (..),
    drepIdHex,
    DRepStatus (..),
    DRepUpdateKind,
    GovActionId (..),
    GovActionState (..),
    GovActionType,
    ProfileRefAC,
    ProfileType,
    SearchKind,
    Vote,
    VoterRole (..),
  )
import Palmares.DomainTypes.Core.Ids (anyVoterIdHex)
import Palmares.DomainTypes.Transfer.Filters
  ( AttestProfileFilter (..),
    AttestationRecordFilter (..),
    DisputeFilter (..),
    emptyAttestProfileFilter,
    emptyAttestationRecordFilter,
    emptyDisputeFilter,
    DelegationFilter (..),
    DRepFilter (..),
    drepFilterFromParams,
    emptyDelegationFilter,
    emptyDRepFilter,
    emptyGovActionFilter,
    emptyGovActivityFilter,
    GovActivityFilter (..),
    emptySPOFilter,
    emptyTreasuryWithdrawalFilter,
    emptyVoteFilter,
    GovActionFilter (..),
    SPOFilter (..),
    TreasuryWithdrawalFilter (..),
    VoteFilter (..),
  )
import Palmares.DomainTypes.Transfer.OrderBy
  ( AttestationsOrderBy (..),
    DelegationsOrderBy (..),
    DelegatorsOrderBy (..),
    DRepsOrderBy (..),
    GovActionsOrderBy (..),
    ProfilesOrderBy (..),
    SortOrder (..),
    SPOsOrderBy (..),
    TreasuryWithdrawalsOrderBy (..),
    VotesOrderBy (..),
  )
import Palmares.DomainTypes.Transfer.QueryResponses
  ( ActivityRow,
    AttestProfileRow,
    AttestationDetailResponse,
    AttestationRow,
    AttestationStatus,
    DisputeRow,
    CommitteeResponse,
    DashboardPageResponse (..),
    DelegationRecord,
    DelegatorRow,
    DRepDetailResponse (..),
    DRepExplorerPageResponse (..),
    DRepMetrics (..),
    DRepSummary,
    DRepUpdateRow,
    EpochPowerPoint,
    GovActionDetailResponse (..),
    GovActionSummary,
    ParamChangeRow (..),
    SearchResults,
    SPOSummary,
    StatusResponse (..),
    TreasuryWithdrawalRecord,
    VoteRecord,
    VoteTally (..),
  )
import Palmares.Metrics.Catalog (MetricFormula, resolvedMetricCatalog, retentionWindowEpochs)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.CSV (CSV)
import Data.Text qualified as T
import Data.Aeson (Value, toJSON)
import Palmares.WebAPI.Envelope (ApiError, ErrorCode (..), Page (..))
import Palmares.WebAPI.Errors (palmaresErrorFormatters, refusedRequestMiddleware)
import Palmares.WebAPI.Utils (addSharedSwaggerDescriptions, markNullableFields)
import Query.Common
  ( PageBounds (..),
    activityBounds,
    boundsFor,
    checkRanges,
    csvBounds,
    epochSeriesBounds,
    hardOffsetCeiling,
    jsonBounds,
    normalizeLimitOffset,
    normalizeQ,
    searchGroupBounds,
  )
import Query.Attest
  ( attestationById,
    attestationSortSpec,
    canonicalGovCredential,
    disputeById,
    listAttestations,
    listDisputes,
    listProfiles,
    profileById,
    profileRefOfUserToken,
    subjectTrackRecordSortSpec,
  )
import Query.Csv ()
import Data.Text.Read qualified as TRead
import Database.Persist.Sql (SqlPersistT)
import Query.Thresholds (drepParamChangeThreshold, paramGroupColumns)
import Query.Gov
  ( FeedDir (..),
    listActivity,
    parseCursor,
    anchorContentQuery,
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
    listTreasuryWithdrawals,
    listSPOs,
    listDelegations,
    getCommittee,
    listVotes,
    resolveDRepHex,
    resolveReservedDRep,
    searchQuery,
    DRepFacets (..),
    DashboardTotals (..),
    dashboardTotalsQuery,
    drepFacetsQuery,
    freshnessQuery,
    listEpochParticipation,
    registeredDRepStatuses,
  )
import Palmares.WebAPI.CORS (CorsConfig, mkCorsMiddleware)
import Palmares.WebAPI.ServiceProbe (ServiceProbe)
import Query.Gov (Freshness (..), freshnessMiddleware)
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
         \disagree. \
         \\n`epoch_params` is the LEDGER's parameters, not the attestation protocol's. The \
         \registry's own oracle parameters -- the dispute deposit a client is about to lock, the \
         \dispute timeout its deadline is computed from, and the arbiter who may write a verdict -- \
         \live in the oracle UTxO's datum, which only a service with a Cardano provider can read: \
         \this one has none by design (it reads `palmares` views over db-sync and never queries \
         \the chain), and db-sync is indexed here without `tx_out`, `datum` or `multi_asset`, so \
         \the UTxO is not reachable from this database either. interaction-api's /status already \
         \reads that datum for `oracle_paused` and is where those numbers are published. \
         \\n`attestation.policy_id` is the minting policy every profile, attestation and dispute \
         \id in this API is scoped to -- the one a wallet filters its own assets by before calling \
         \/profiles/by-user-token. It is null on a governance-only deployment, where the whole \
         \`attestation` block is absent."
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
         \that have one - the SQL statement that defines it, inlined. One of them is executed \
         \verbatim (delegator_retention_rate_v1). The five DRep metrics are served from a \
         \materialized view that implements the same arithmetic batched over every DRep, and its \
         \agreement with these statements is asserted by a test over a seeded corpus and by a \
         \check against a synced database - not assumed."
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
        drepFilterFromParams
          status
          anchorStatus
          hasScript
          minPower
          maxPower
          minDelegators
          minPart
          minRat
          regBefore
          regAfter
          minAge
          votedOn
          notVotedOn
          lang
          activeEpoch
          q'
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

-- | A DRep or a reserved ledger option, with the @target_kind@ its power rows carry.
--
-- 'drepIdHex' answers 'Nothing' for a reserved view — it has no credential — which is exactly how
-- the two cases are told apart without a second parser.
resolveDRepTarget :: DRepId -> QueryAppMonad (Text, Int64)
resolveDRepTarget did = case drepIdHex did of
  Just hex -> do
    mid <- runRead (resolveDRepHex hex)
    (,) "drep" <$> maybe (throwApi DrepNotFound) pure mid
  Nothing -> do
    let view_ = unDRepId did
    mid <- runRead (resolveReservedDRep view_)
    -- The kind in drep_epoch_power is the view without its `drep_` prefix: `always_abstain`.
    (,) (fromMaybe view_ (T.stripPrefix "drep_" view_)) <$> maybe (throwApi DrepNotFound) pure mid

handleGetDRepDetail :: DRepId -> QueryAppMonad DRepDetailResponse
handleGetDRepDetail did = do
  dhid <- resolveDRep did
  -- ONE runRead, so the whole page is one RepeatableRead snapshot: a composite assembled from
  -- several transactions can show metrics from one moment beside a delegator list from another.
  r <- runRead $ do
    ms <- drepSummaryByIdQuery dhid
    mm <- drepMetricsQuery dhid
    power <- listEpochPower "drep" dhid Nothing Nothing Asc 200
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
  -- The reserved ledger options are served HERE and nowhere else on this route family, and the
  -- asymmetry is the data rather than an oversight: they have a power series and nothing else — no
  -- registration, no metadata, no votes — so /drep/{id} still answers 404 for them while this
  -- answers. D-20's rule is that a consumer must be able to see them; before this they were
  -- reachable only as an aggregate on /pages/dashboard.
  (kind, dhid) <- resolveDRepTarget did
  _ <- either throwApi pure (checkRanges Nothing Nothing fromEpoch toEpoch)
  (lim, off) <- either throwApi pure (normalizeLimitOffset epochSeriesBounds limit Nothing)
  points <- runRead (listEpochPower kind dhid fromEpoch toEpoch (fromMaybe Asc sortOrder) lim)
  -- total = the number of points returned: the series is at most 200 rows and a second COUNT
  -- query over it would cost as much as the page.
  pure (Page points (Just (length points)) lim off Nothing)

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
  (txHex, actionIx) <- maybe (throwApi InvalidGovActionId) pure (splitActionId gid)
  r <- runRead $ do
    mid <- resolveGovAction txHex actionIx
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

--  Votes

------------------------------------------------------------------------------------------------

type VotesAPI =
  Summary "Votes"
    :> Description
         "Every vote cast, across all three voter roles, with the rationale anchor's outcome and \
         \the voter's power at the epoch the action's window closed. One endpoint rather than four \
         \per-actor routes: the filters are repeatable, so a DRep's record, an action's votes, a \
         \committee member's votes and the global feed are all the same query. \
         \\n`voter_id` accepts any identifier form -- drep1y…, cc_cold1…, pool1… or 56 hex \
         \characters -- and committee votes are addressed by the COLD credential, the identity \
         \that survives a hot-key rotation, with the signing hot key published beside it. \
         \\nRe-votes are returned as rows, not hidden: `revote_count` says how many exist for that \
         \(voter, action) pair and `is_final` / `is_first` mark which one a verdict or a latency is \
         \measured from. preprod's worst pair has 21,626 rows, from the epoch-187 committee stress \
         \test. \
         \\n`is_final=true` is the parameter most clients want and the one that makes this endpoint \
         \usable: it keeps one row per (voter, action) -- the vote that counts -- which on preprod \
         \turns 3,244,723 rows into 931, and 65,000 pages into 19. `is_final=false` returns only the \
         \superseded votes, which is the audit question \"who changed their mind\". Omit it and you \
         \get every row, including every re-vote. \
         \\nThere is no `has_rationale` parameter: it is `anchor_status=valid`, which makes the \
         \caller say which of the five anchor outcomes they mean instead of collapsing an \
         \unreachable IPFS document into \"no rationale\"."
    :> "votes"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "voter_role" VoterRole
    :> QueryParams "voter_id" Text
    :> QueryParams "gov_action_id" GovActionId
    :> QueryParams "verdict" Vote
    :> QueryParams "gov_action_type" GovActionType
    :> QueryParams "anchor_status" AnchorStatus
    :> QueryParam "from" UTCTime
    :> QueryParam "to" UTCTime
    :> QueryParam "from_epoch" Int
    :> QueryParam "to_epoch" Int
    :> QueryParam "q" Text
    :> QueryParam "is_final" Bool
    :> QueryParam "order_by" VotesOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page VoteRecord)

handleGetVotes ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [VoterRole] ->
  [Text] ->
  [GovActionId] ->
  [Vote] ->
  [GovActionType] ->
  [AnchorStatus] ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe Int ->
  Maybe Int ->
  Maybe Text ->
  Maybe Bool ->
  Maybe VotesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page VoteRecord)
handleGetVotes accept limit offset roles voterIds gaIds verdicts gaTypes anchorStatus fromTime toTime fromEpoch toEpoch q isFinal orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  _ <- either throwApi pure (checkRanges fromTime toTime fromEpoch toEpoch)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  -- Every voter_id must decode, and a bad one is a 400 rather than an empty page: a client that
  -- mistyped an identifier should be told, not shown "this voter never voted".
  hexes <- mapM (maybe (throwApi InvalidDrepId) pure . anyVoterIdHex) voterIds
  let filt =
        emptyVoteFilter
          { voteFilterRoles = roles,
            voteFilterVoterIds = hexes,
            voteFilterGovActionIds = gaIds,
            voteFilterVerdicts = verdicts,
            voteFilterGovActionTypes = gaTypes,
            voteFilterAnchorStatus = anchorStatus,
            voteFilterFrom = fromTime,
            voteFilterTo = toTime,
            voteFilterFromEpoch = fromEpoch,
            voteFilterToEpoch = toEpoch,
            voteFilterQ = q',
            voteFilterIsFinal = isFinal
          }
  runRead (listVotes filt (fromMaybe VotesOrderByCastAt orderBy, fromMaybe Desc sortOrder) bounds)

votesServer :: ServerT VotesAPI QueryAppMonad
votesServer = handleGetVotes

------------------------------------------------------------------------------------------------

--  Activity

------------------------------------------------------------------------------------------------

-- | @GET \/activity@ — the governance feed.
--
-- __Cursor-paged, not offset-paged, and that is the one endpoint where the difference is
-- visible to a client.__ Everything else here takes @offset@; this takes @cursor@, publishes
-- @next_cursor@, and publishes @total: null@. Three reasons, in order of how much they cost:
--
--   1. The feed MOVES. New blocks arrive at the head, so page 2 by offset re-shows rows page 1
--      already showed, which is the one bug every infinite scroll has.
--   2. Counting it means a pass over all eleven arms — 3.9 M rows, 3.24 M of them votes. F-17's
--      rule is that a total must come from the same pass as the rows, and a keyset page has no
--      such pass, so it publishes no total rather than one that disagrees with the page.
--   3. @OFFSET 200000@ over a @UNION ALL@ still materialises the 200,000 rows it throws away.
--
-- __JSON only, where the other list endpoints also serve CSV.__ A CSV export is a whole result
-- set; this endpoint cannot say how large its result set is, so @\/activity.csv@ would be one page
-- of a feed with no way to ask for the next. The per-family exports (@\/votes@, @\/dreps@,
-- @\/delegations@, @\/treasury-withdrawals@) are where a bulk reader already gets the same events
-- with a total and a stable order.
type ActivityAPI =
  Summary "Governance activity feed"
    :> Description
         "Every governance event on one timeline, newest first: DRep registrations, updates and \
         \retirements; votes; proposals; vote-delegation changes; committee hot-key \
         \authorisations and resignations; and the ledger's own epoch-boundary outcomes \
         \(ratified, enacted, expired, dropped, and a treasury withdrawal paying out). \
         \\nPaged by CURSOR, never by offset: an offset over a feed that grows at the head \
         \re-shows rows the previous page already showed. Two directions, and at most one of \
         \them per request: `before` walks backwards in time for an infinite scroll, `since` \
         \walks forwards for a catch-up poll and returns its page in ASCENDING order. Neither \
         \means newest-first from the tip. Both at once is a 400 `both_cursors_given`, because \
         \the two would name different directions for one page. \
         \\nPass back the `next_cursor` the previous page carried. A page shorter than `limit` \
         \is the end of the feed in that direction and carries no `next_cursor`. `total` is \
         \always null -- counting 3.9M union rows on every page is the cost this endpoint \
         \exists to avoid, and a count from a different pass than the rows is a count that \
         \disagrees with them. \
         \\n`offset` is not a parameter here. Servant ignores an undeclared query parameter, so \
         \`?offset=10` is served as the unpaged request it is rather than refused. \
         \\nThe five epoch-boundary kinds have `at.slot` and `at.tx_hash` null TOGETHER: they \
         \happen in the ledger at an epoch boundary with no transaction to point at. `at.epoch` \
         \and `at.time` are always present. \
         \\n`actor_id` and `target_id` are text whose meaning depends on `event_type` -- a \
         \credential in hex, a stake address in bech32, or a governance action id. `actor` \
         \matches either form, so `drep1y...` and its 56 hex characters find the same events."
    :> "activity"
    :> QueryParam "before" Text
    :> QueryParam "since" Text
    :> QueryParam "limit" Int
    :> QueryParams "event_type" ActivityEventType
    :> QueryParams "source" ActivitySource
    :> QueryParams "actor" Text
    :> Get '[JSON] (Page ActivityRow)

handleGetActivity ::
  Maybe Text ->
  Maybe Text ->
  Maybe Int ->
  [ActivityEventType] ->
  [ActivitySource] ->
  [Text] ->
  QueryAppMonad (Page ActivityRow)
handleGetActivity before since limit eventTypes sources actors = do
  -- Both cursors is a 400 and not a precedence rule. A request that names two directions has no
  -- single answer, and silently preferring one of them would page a client the way it did not ask
  -- for while reporting success.
  (dir, raw) <- case (before, since) of
    (Just _, Just _) -> throwApi BothCursorsGiven
    (_, Just c) -> pure (Newer, Just c)
    (mb, Nothing) -> pure (Older, mb)
  cur <- maybe (pure Nothing) (fmap Just . either throwApi pure . parseCursor) raw
  (lim, _) <- either throwApi pure (normalizeLimitOffset activityBounds limit Nothing)
  let filt =
        emptyGovActivityFilter
          { govActivityFilterEventTypes = eventTypes,
            govActivityFilterSources = sources,
            govActivityFilterActors = actors
          }
  runRead (listActivity filt dir cur lim)

activityServer :: ServerT ActivityAPI QueryAppMonad
activityServer = handleGetActivity

------------------------------------------------------------------------------------------------

--  Search

------------------------------------------------------------------------------------------------

-- | @GET /search@ — the command palette.
--
-- @q@ is REQUIRED, which is spelled in the TYPE rather than checked in the handler: a @Required@
-- parameter makes servant refuse the request before it reaches a handler, and
-- 'palmaresErrorFormatters' turns that into the documented @{code, message}@ body. An optional @q@
-- would mean "no filter", and no filter on a palette is a request for the whole registry.
type SearchAPI =
  Summary "Command-palette search"
    :> Description
         "One request behind the command palette: DReps by published name, governance actions by \
         \title or abstract, stake pools by ticker or metadata name, and any of them by a pasted \
         \identifier. Six groups ALWAYS travel, each capped at `limit_per_group`, so a missing \
         \section is an empty one rather than an absent key; `profiles` and `attestations` are \
         \always empty here and are filled over the attestation schema later. `total` is across \
         \the whole match, not across the page. \
         \\nA pasted identifier is matched by EQUALITY after its bech32 checksum verifies -- \
         \drep1y…, drep1…, cc_cold1…, cc_hot1…, pool1…, 56 hex characters, gov_action1… or \
         \<tx_hash>#<index> with the # sent as %23. A PARTIAL identifier is not matched: `pool1` \
         \is a prefix of all 686 preprod pools, so prefix-matching a five-character paste would \
         \return the whole table. \
         \\nText matching is substring and case-insensitive, and a % or _ the user typed is \
         \matched literally -- measured, q=_a returns nothing where an unescaped pattern would \
         \return 39 hits. \
         \\nWhat is searchable is set by what db-sync has fetched, and on preprod that is narrow: \
         \64 of 805 DRep credentials carry a name, 7 of 131 actions carry a title, NO pool carries \
         \off-chain metadata, and a committee member has no name in db-sync at all -- so that \
         \group answers an identifier and nothing else. A hit with no text shows its identifier as \
         \its title. \
         \\nUnlike /dreps, no status filter is applied: a retired DRep is still something you look \
         \up by name."
    :> "search"
    :> QueryParam' '[Required, Strict] "q" Text
    :> QueryParams "kinds" SearchKind
    :> QueryParam "limit_per_group" Int
    :> Get '[JSON] SearchResults

handleGetSearch :: Text -> [SearchKind] -> Maybe Int -> QueryAppMonad SearchResults
handleGetSearch q kinds limitPerGroup = do
  -- normalizeQ answers Nothing only for a Nothing input, which a Required parameter cannot be.
  -- The fromMaybe arm is therefore unreachable, and is spelled rather than fromJust so a later
  -- change to normalizeQ cannot make this partial.
  qt <- fromMaybe q <$> either throwApi pure (normalizeQ (Just q))
  -- The offset half is unused: a palette has no second page, it has a narrower query.
  (lim, _) <- either throwApi pure (normalizeLimitOffset searchGroupBounds limitPerGroup Nothing)
  runRead (searchQuery qt kinds lim)

searchServer :: ServerT SearchAPI QueryAppMonad
searchServer = handleGetSearch

------------------------------------------------------------------------------------------------

--  Delegations

------------------------------------------------------------------------------------------------

type DelegationsAPI =
  Summary "Vote delegations"
    :> Description
         "One row per stake address: the delegation it currently holds, and whether that \
         \delegation still counts. Not one row per certificate -- a superseded certificate is not \
         \the latest one, so it is not a row here, and `is_current=false` means one thing only: \
         \the stake account was deregistered AFTER the delegation's certificate. \
         \preprod has 2,304 addresses that have ever delegated, 2,015 of which currently count. \
         \\n`is_current` DEFAULTS TO TRUE and filters both ways, which is a deliberate difference \
         \from /drep/{id}/delegators, where is_current=false widens to the history instead. \
         \\n`drep_id` accepts a credential in any form -- drep1y..., drep1..., 56 hex characters -- \
         \and also either reserved ledger option. Those two are not a special case: of the 2,015 \
         \current delegations, 1,020 name drep_always_abstain and 40 drep_always_no_confidence, so \
         \the reserved options hold the majority of delegated stake. \
         \\n`lovelace` is the stake the ledger counted at the latest snapshot and is null for an \
         \address with no stake in it."
    :> "delegations"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "drep_id" DRepId
    :> QueryParams "stake_address" Text
    :> QueryParam "is_current" Bool
    :> QueryParam "from" UTCTime
    :> QueryParam "to" UTCTime
    :> QueryParam "min_lovelace" Int64
    :> QueryParam "order_by" DelegationsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page DelegationRecord)

handleGetDelegations ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [DRepId] ->
  [Text] ->
  Maybe Bool ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe Int64 ->
  Maybe DelegationsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page DelegationRecord)
handleGetDelegations accept limit offset drepIds stakeAddrs isCurrent fromTime toTime minLovelace orderBy sortOrder = do
  _ <- either throwApi pure (checkRanges fromTime toTime Nothing Nothing)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptyDelegationFilter
          { delegationFilterDrepHex = hexes,
            delegationFilterReservedTargets = reserved,
            delegationFilterStakeAddresses = stakeAddrs,
            delegationFilterIsCurrent = fromMaybe True isCurrent,
            delegationFilterFrom = fromTime,
            delegationFilterTo = toTime,
            delegationFilterMinLovelace = minLovelace
          }
  runRead (listDelegations filt (fromMaybe DelegationsOrderByAt orderBy, fromMaybe Desc sortOrder) bounds)
  where
    -- A reserved option and a credential match different columns, so they are split here rather
    -- than in SQL. `drepIdHex` returning Nothing is UNAMBIGUOUS at this point: the DRepId parser
    -- already rejected anything malformed as invalid_drep_id, so the only well-formed id with no
    -- 28-byte hash behind it is one of the two reserved views -- and `drep_` is the prefix
    -- `Core.reservedDRepViews` gives them.
    (reserved, hexes) = partitionEithers (map split1 drepIds)
    split1 did = maybe (Left (T.drop 5 (unDRepId did))) Right (drepIdHex did)

delegationsServer :: ServerT DelegationsAPI QueryAppMonad
delegationsServer = handleGetDelegations

------------------------------------------------------------------------------------------------

--  The constitutional committee

------------------------------------------------------------------------------------------------

-- | No parameters, no pagination and no CSV: there is exactly one committee in force and it has
-- three seats. It is its own composite, and there is no /committees list.
type CommitteeAPI =
  Summary "The constitutional committee in force"
    :> Description
         "The committee the ledger is currently applying, with its quorum, the governance action \
         \that established it, and its seats inline. `epoch` is the epoch of the epoch_state row \
         \that names this committee, so a client can see which moment the answer is as of. \
         \\nEach seat is identified by its COLD credential, the identity that survives a hot-key \
         \rotation, with the signing hot key published beside it -- the same choice /votes makes. \
         \preprod shows why at scale: 648,767 hot-key registrations resolve to 43 cold \
         \credentials, and `votes_cast` counts distinct governance actions through all of a \
         \member's registrations so one record does not split across rotations. \
         \\n`status` has two values, active and resigned, not Koios's four: it is derived from \
         \committee_de_registration alone, and expiry is published beside it as \
         \`expiration_epoch` rather than folded in, because a member whose term ends in a future \
         \epoch is serving today."
    :> "committee"
    :> Get '[JSON] CommitteeResponse

-- | A 404 and not an empty object: no epoch_state row naming a committee means the ledger has not
-- produced one yet, which is a thing that does not exist rather than a committee with no members.
handleGetCommittee :: QueryAppMonad CommitteeResponse
handleGetCommittee = runRead getCommittee >>= maybe (throwApi CommitteeNotFound) pure

committeeServer :: ServerT CommitteeAPI QueryAppMonad
committeeServer = handleGetCommittee

------------------------------------------------------------------------------------------------

--  SPOs

------------------------------------------------------------------------------------------------

type SPOsAPI =
  Summary "Stake pools in the voting-power distribution"
    :> Description
         "The pools in pool_stat at its latest epoch -- 510 on preprod at epoch 320 -- ordered by \
         \voting power descending. This is the DISTRIBUTION, not the set of pools that have voted: \
         \45 pools have ever cast an SPO vote and only 39 of those are still in the distribution, \
         \six voters having since retired. min_votes_cast=1 therefore returns 39, and \
         \/votes?voter_role=spo is the endpoint that answers who voted. \
         \\n`votes_cast` counts DISTINCT governance actions, not vote rows: one preprod pool has 8 \
         \rows across 4 actions. \
         \\n`ticker` is null throughout F1 because db-sync's pool-metadata fetcher is disabled and \
         \off_chain_pool_data has 0 rows. `participation_rate` is null because there is no \
         \spo_participation_rate_v1 in the metric catalog, and every number this API publishes \
         \carries the id of the formula that produced it -- a rate with no resolvable formula \
         \would break that contract. \
         \\nThere is no `q` parameter: an SPO row is a direct pool_stat/pool_hash read with no text \
         \column to match. Exact id lookup is what /search is for."
    :> "spos"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParam "min_voting_power" Int64
    :> QueryParam "min_votes_cast" Int
    :> QueryParam "active_in_epoch" Int
    :> QueryParam "order_by" SPOsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page SPOSummary)

handleGetSPOs ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  Maybe Int64 ->
  Maybe Int ->
  Maybe Int ->
  Maybe SPOsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page SPOSummary)
handleGetSPOs accept limit offset minPower minVotes activeEpoch orderBy sortOrder = do
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptySPOFilter
          { spoFilterMinVotingPower = minPower,
            spoFilterMinVotesCast = minVotes,
            spoFilterActiveInEpoch = activeEpoch
          }
  runRead (listSPOs filt (fromMaybe SPOsOrderByVotingPower orderBy, fromMaybe Desc sortOrder) bounds)

sposServer :: ServerT SPOsAPI QueryAppMonad
sposServer = handleGetSPOs

------------------------------------------------------------------------------------------------

--  Treasury withdrawals

------------------------------------------------------------------------------------------------

type TreasuryWithdrawalsAPI =
  Summary "Treasury withdrawals"
    :> Description
         "Every treasury payment a governance action would make, across all actions -- the list \
         \form of the `withdrawals` block inside /gov-action/{id}. preprod has 83 of them across \
         \82 actions to 19 beneficiaries. \
         \\nNONE has ever been enacted, so `enacted_epoch` and `enacted_at` are null on every row \
         \and `paid_heuristic` is false on every row. `enacted_epoch` is the only authoritative \
         \enactment value db-sync has; `enacted_at` is an epoch-boundary chain point with no slot \
         \and no transaction hash, because the ledger pays a withdrawal at an epoch boundary and \
         \there is nothing to point at. \
         \\n`paid_heuristic` carries its warning in its name: reward_rest has no \
         \governance-action key, so matching a payment by (stake_address, spendable_epoch) is \
         \ambiguous when one address receives two withdrawals in one epoch. \
         \\nThere is no /treasury-withdrawal/{id}: a withdrawal is addressed by its action, which \
         \/gov-action/{id} already serves."
    :> "treasury-withdrawals"
    :> Header "Accept" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "gov_action_id" GovActionId
    :> QueryParams "beneficiary" Text
    :> QueryParam "enacted_from_epoch" Int
    :> QueryParam "enacted_to_epoch" Int
    :> QueryParam "min_amount" Int64
    :> QueryParam "max_amount" Int64
    :> QueryParam "order_by" TreasuryWithdrawalsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON, CSV] (Page TreasuryWithdrawalRecord)

handleGetTreasuryWithdrawals ::
  Maybe Text ->
  Maybe Int ->
  Maybe Int ->
  [GovActionId] ->
  [Text] ->
  Maybe Int ->
  Maybe Int ->
  Maybe Int64 ->
  Maybe Int64 ->
  Maybe TreasuryWithdrawalsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page TreasuryWithdrawalRecord)
handleGetTreasuryWithdrawals
  accept limit offset gaIds beneficiaries fromEpoch toEpoch minAmt maxAmt orderBy sortOrder = do
  _ <- either throwApi pure (checkRanges Nothing Nothing fromEpoch toEpoch)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptyTreasuryWithdrawalFilter
          { withdrawalFilterGovActionIds = gaIds,
            withdrawalFilterBeneficiaries = beneficiaries,
            withdrawalFilterEnactedFromEpoch = fromEpoch,
            withdrawalFilterEnactedToEpoch = toEpoch,
            withdrawalFilterMinAmount = minAmt,
            withdrawalFilterMaxAmount = maxAmt
          }
  runRead
    ( listTreasuryWithdrawals
        filt
        (fromMaybe TreasuryWithdrawalsOrderByEnactedEpoch orderBy, fromMaybe Desc sortOrder)
        bounds
    )

treasuryWithdrawalsServer :: ServerT TreasuryWithdrawalsAPI QueryAppMonad
treasuryWithdrawalsServer = handleGetTreasuryWithdrawals

type DRepExplorerPageAPI =
  Summary "DRep explorer page"
    :> Description
         "One page of /dreps with the four counts its sidebar renders, in a single snapshot. The \
         \rows and the total are /dreps' own -- this endpoint adds facets to that list rather than \
         \re-deriving it -- and every parameter means exactly what it means there. \
         \\nThe three enumerated facets are counted over the applied filter set WITH THAT FACET'S \
         \OWN PREDICATE REMOVED, so the sidebar can offer `Retired (511)` while `status=active` is \
         \applied. They therefore sum to every registered credential (measured: 805) and not to \
         \the 294 the list shows. `power_buckets` is NOT a facet in that sense: it is a range \
         \control, so it follows the filter as applied and its counts sum to `total`. \
         \\n`reserved` never appears among the statuses: the two reserved ledger options hold \
         \stake but no credential, and are published by /pages/dashboard instead."
    :> "pages"
    :> "drep-explorer"
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
    :> Get '[JSON] DRepExplorerPageResponse

handleGetDRepExplorerPage ::
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
  QueryAppMonad DRepExplorerPageResponse
handleGetDRepExplorerPage
  limit offset status anchorStatus hasScript minPower maxPower minDelegators minPart minRat
  regBefore regAfter minAge votedOn notVotedOn lang activeEpoch q orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  _ <- either throwApi pure (checkRanges regAfter regBefore Nothing Nothing)
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  let filt =
        drepFilterFromParams
          status
          anchorStatus
          hasScript
          minPower
          maxPower
          minDelegators
          minPart
          minRat
          regBefore
          regAfter
          minAge
          votedOn
          notVotedOn
          lang
          activeEpoch
          q'
  -- ONE runRead, for the reason handleGetDRepDetail gives: a sidebar counted in one transaction
  -- beside a list read in another can disagree with it across a matview refresh.
  r <- runRead $ do
    mf <- freshnessQuery
    page <- listDReps filt (fromMaybe DRepsOrderByVotingPower orderBy, fromMaybe Desc sortOrder) bounds
    mfacets <- drepFacetsQuery filt
    pure $ do
      fr <- mf
      fc <- mfacets
      pure
        DRepExplorerPageResponse
          { drepExplorerItems = pageItems page,
            drepExplorerTotal = fromMaybe 0 (pageTotal page),
            drepExplorerLimit = pageLimit page,
            drepExplorerOffset = pageOffset page,
            drepExplorerEpoch = freshEpoch fr,
            drepExplorerStatusFacets = facetStatus fc,
            drepExplorerAnchorFacets = facetAnchor fc,
            drepExplorerLanguageFacets = facetLanguage fc,
            drepExplorerPowerBuckets = facetPower fc
          }
  -- The only Nothing is an empty palmares.sync_state -- a database with no blocks -- which is what
  -- IndexerBehind means. The facet statement's outer SELECT has no FROM and always returns a row.
  maybe (throwApi IndexerBehind) pure r

-- | @GET \/pages\/dashboard@ — the registry's front page in one snapshot.
type DashboardPageAPI =
  Summary "Dashboard page"
    :> Description
         "Every headline figure in one request and one transaction: how many DReps there are and \
         \in what state, how much stake is parked on the two reserved ledger options against how \
         \much is delegated to real DReps, every governance action by type and by state, what is \
         \still votable, what closes next, the treasury's requested and enacted totals, the \
         \current power leaderboard, and DRep participation epoch by epoch. \
         \\nThe DRep counts, the leaderboard rows and the closing-soon rows are /dreps' and \
         \/gov-actions' own -- the same queries, so no figure here can disagree with the list it \
         \links to. `total_dreps` is the universe /dreps lists by default (registered = active + \
         \inactive); `retired_dreps` is published beside it, never inside it, because preprod has \
         \511 retired against 294 registered. \
         \\n`power_epoch` is its own field because the ledger writes the DRep stake distribution \
         \one epoch behind the tip, so the three lovelace figures are a different moment from \
         \everything else and say so. \
         \\n`actions_in_flight` is `last_votable_epoch >= epoch`, which is not `state = proposed`: \
         \measured 12 against 11, the extra one being an action whose state already reads expired \
         \while its window is still open. \
         \\nThe treasury is TWO numbers because 83 withdrawals are recorded on preprod and none \
         \has been enacted, so one field called `withdrawn` would be either 0 -- true, and reads \
         \as no treasury activity -- or the requested total, which is a lie about the word."
    :> "pages"
    :> "dashboard"
    :> QueryParam "top_limit" Int
    :> QueryParam "closing_soon_limit" Int
    :> QueryParam "epochs" Int
    :> Get '[JSON] DashboardPageResponse

-- | @\/pages\/dashboard@'s three sizes.
--
-- Named rather than spelled at the call site, which is 'PageBounds'' own stated reason to exist —
-- and here it became load-bearing: 'publishPageBounds' has to publish the same three pairs in the
-- Swagger document, and a second copy of @PageBounds 50 10@ in a table forty lines away is exactly
-- the shape where the documented ceiling and the applied one drift apart with nothing to notice it.
-- One definition, read by the handler and by the document.
dashboardTopBounds, dashboardClosingSoonBounds, dashboardEpochsBounds :: PageBounds
dashboardTopBounds = PageBounds 50 10
dashboardClosingSoonBounds = PageBounds 20 5
dashboardEpochsBounds = PageBounds 100 20

handleGetDashboardPage ::
  Maybe Int -> Maybe Int -> Maybe Int -> QueryAppMonad DashboardPageResponse
handleGetDashboardPage topLimit closingSoonLimit epochsParam = do
  -- The three sizes are clamped by the SAME helper every page uses, so they clamp silently rather
  -- than refusing, and the applied value is the one the response was built from.
  (topLim, _) <- either throwApi pure (normalizeLimitOffset dashboardTopBounds topLimit Nothing)
  (soonLim, _) <- either throwApi pure (normalizeLimitOffset dashboardClosingSoonBounds closingSoonLimit Nothing)
  (epochs, _) <- either throwApi pure (normalizeLimitOffset dashboardEpochsBounds epochsParam Nothing)
  r <- runRead $ do
    mf <- freshnessQuery
    -- The DRep counts come from the EXPLORER's facet statement, with no filter: one derivation of
    -- 294, published by two endpoints. The other three facet lists are computed in the same pass
    -- and dropped, which costs nothing -- measured, the join is the whole cost of that statement.
    mfacets <- drepFacetsQuery emptyDRepFilter {drepFilterStatus = registeredDRepStatuses}
    mtotals <- dashboardTotalsQuery
    case (mf, mfacets, mtotals) of
      (Just fr, Just fc, Just ts) -> do
        -- expiration < epoch + 6 is "expires within five epochs", because the filter is strict.
        soon <-
          listGovActions
            emptyGovActionFilter
              { govActionFilterStates = [Proposed],
                govActionFilterExpiresBeforeEpoch = Just (freshEpoch fr + 6)
              }
            (GovActionsOrderByExpiresEpoch, Asc)
            (soonLim, 0)
        tops <- listDReps emptyDRepFilter (DRepsOrderByVotingPower, Desc) (topLim, 0)
        part <- listEpochParticipation epochs
        let n = fromMaybe 0 . flip lookup (facetStatus fc)
        pure . Just $
          DashboardPageResponse
            { dashboardEpoch = freshEpoch fr,
              -- ALL THREE REGISTERED STATUSES. This was `active + inactive`, which drops the
              -- `unknown` ones — registered credentials for which the ledger recorded no activity
              -- deadline — and on preprod that is 90 of 294: the dashboard headline read 204 while
              -- the explorer it links to listed 294, with no `unknown_dreps` field for a client to
              -- reconstruct the difference from. The comment above states the invariant this broke:
              -- one derivation of the registered population, published by two endpoints.
              dashboardTotalDreps = n DRepActive + n DRepInactive + n DRepUnknown,
              dashboardActiveDreps = n DRepActive,
              dashboardInactiveDreps = n DRepInactive,
              dashboardRetiredDreps = n DRepRetired,
              dashboardPowerEpoch = totalsPowerEpoch ts,
              dashboardDrepPowerLovelace = totalsDrepPowerLovelace ts,
              dashboardAlwaysAbstainLovelace = totalsAlwaysAbstainLovelace ts,
              dashboardAlwaysNoConfidenceLovelace = totalsAlwaysNoConfidenceLovelace ts,
              dashboardTotalActions = totalsTotalActions ts,
              dashboardActionsInFlight = totalsActionsInFlight ts,
              dashboardActionsByType = totalsActionsByType ts,
              dashboardActionsByState = totalsActionsByState ts,
              dashboardTreasuryRequestedLovelace = totalsTreasuryRequestedLovelace ts,
              dashboardTreasuryEnactedLovelace = totalsTreasuryEnactedLovelace ts,
              dashboardClosingSoon = pageItems soon,
              dashboardTopDrepsByPower = pageItems tops,
              dashboardParticipationByEpoch = part
            }
      _ -> pure Nothing
  maybe (throwApi IndexerBehind) pure r

------------------------------------------------------------------------------------------------

--  The attestation read surface (the palmares_attest projections)

------------------------------------------------------------------------------------------------

-- | @GET \/profiles@ — the registry list.
--
-- JSON only, where the governance lists also serve CSV. This is the claim → attest → verify flow's
-- own surface and nothing exports it: a CSV of it would be a @ToNamedRecord@ and a
-- @DefaultOrdered@ per DTO for a screen that pages. @\/dreps@ and @\/votes@ are where a bulk
-- reader already gets a whole result set in one request.
type ProfilesAPI =
  Summary "Profiles"
    :> Description
         "Every profile the registry has projected from chain: who it says it is, what kind of \
         \actor it stands for, and the governance credential it CLAIMS. \
         \\n`credential` is a claim and not a proof -- nothing on chain checks that the claimant \
         \controls the credential, and the same credential may be claimed by more than one \
         \profile. `claimed=true` narrows to the profiles that claim one at all, which is the \
         \subset a verification screen has anything to check. \
         \\n`credential_is_script` travels beside the string and is DECODED from its CIP-129 \
         \header byte, never inferred: a key credential and a script credential can share a hash \
         \and are not the same actor. \
         \\n`slot` is the only time a projection row carries -- a wall clock stamped at ingest \
         \would be re-stamped by every rollback replay -- and it is published raw, because this \
         \service holds no slot configuration and a second slot-to-time conversion that can \
         \disagree with the chain's is worse than a slot number. \
         \\n`q` matches name and description, case-insensitively, with any % or _ the user typed \
         \matched literally. Default ordering is registered_at descending."
    :> "profiles"
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParams "kind" ProfileType
    :> QueryParam "claimed" Bool
    :> QueryParam "q" Text
    :> QueryParam "order_by" ProfilesOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page AttestProfileRow)

type ProfileDetailAPI =
  Summary "Profile"
    :> Description
         "One profile by its asset class, `<policy_id>.<token_name_hex>` -- the form /profiles \
         \returns and the admin CLI accepts. 404 `profile_not_found` when no projection carries \
         \that id, which includes an id that exists on chain but has not been projected yet."
    :> "profiles"
    :> Capture "profile-id" ProfileRefAC
    :> Get '[JSON] AttestProfileRow

-- | @GET \/profiles\/by-credential\/{credential}@ — the verify lookup.
--
-- Declared BEFORE 'ProfileDetailAPI' in 'CoreFunctionAPI'. Servant prefers a static path segment
-- over a capture at the same position, so the order is belt and braces rather than the only thing
-- holding the route apart from @\/profiles\/{profile-id}@ — but a failing @Capture@ is
-- @FailFatal@, so if that preference ever changed, @by-credential@ would come back as a 400 from
-- the asset-class parser rather than falling through. One line of ordering is cheaper than
-- finding that out.
type ProfilesByCredentialAPI =
  Summary "Profiles claiming a governance credential"
    :> Description
         "The verify direction: given a governance credential, which profiles claim it. \
         \\n**ALL THREE CLAIMABLE ROLES.** `drep1y...`, `cc_cold1z...` and `cc_hot1q...` are \
         \accepted, each in its key and script form. ADR 0006 makes all three claimable -- the \
         \role lives in the CIP-129 header byte rather than in the profile's `kind`, because an \
         \Organization may be a DRep and a Committee may hold both committee credentials -- and \
         \the write side has always accepted all three. This route accepted only `drep`, so a \
         \committee credential the registry already held a claim for answered 400 \
         \`invalid_drep_id` (\"Not a DRep identifier\"), which is true of the input and useless to \
         \the caller. \
         \\n**CIP-129 ONLY.** The CIP-105 form `drep1...` and 56 bare hex characters are REFUSED \
         \with 400 `invalid_credential`, although every other route here accepts all three DRep \
         \forms. The reason is that neither of those two carries a header byte and `drep` is the \
         \HRP for both credential kinds, so neither can say whether the credential is a key or a \
         \script -- and the projection stores the full CIP-129 string the datum claimed. Accepting \
         \one would mean choosing a header byte to compare against, and choosing the key byte \
         \(which the governance routes do, then resolve the row by its 28-byte hash and re-render \
         \from db-sync's own has_script) would silently report every script DRep as a key DRep and \
         \find no claim for the script profile that exists. There is no row to ask here, so the \
         \caller is asked instead. \
         \\nAn identifier whose header byte disagrees with its HRP -- a `drep1...` carrying a \
         \committee header -- is also refused, rather than being read as either: two different \
         \claims about the same 28 bytes give no reason to prefer one. \
         \\nA non-canonical bech32 spelling of an accepted form still matches: the id is decoded \
         \and re-encoded before it reaches the query. \
         \\nPAGED, and `total` is the answer to \"is this contested\": 0 is an unclaimed \
         \credential, 1 is a single claim, more than 1 means several profiles claim the same \
         \credential and this API does not pick a winner. Ordered OLDEST CLAIM FIRST, by slot, so \
         \the first row is deterministically the first claimant rather than whichever row the \
         \database returned first."
    :> "profiles"
    :> "by-credential"
    :> Capture "credential" Text
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> Get '[JSON] (Page AttestProfileRow)

-- | @GET \/profiles\/by-user-token\/{asset-class}@ — the wallet lookup.
--
-- Declared BEFORE 'ProfileDetailAPI' in 'CoreFunctionAPI', for the reason
-- 'ProfilesByCredentialAPI' gives: a failing @Capture@ is @FailFatal@, so a static segment that
-- came after the capture would be answered by the asset-class parser's 400 rather than falling
-- through to this route.
--
-- __It takes a 'Text' and not a 'ProfileRefAC', and that is the point.__ The capture is the asset
-- class of the token the WALLET holds — the CIP-68 user half — which is a well-formed asset class
-- that is not a profile id, so typing it as @ProfileRefAC@ would let Atlas's parser accept it and
-- then look up a row that cannot exist. 'profileRefOfUserToken' is the derivation, and a value it
-- refuses is @400 invalid_asset_class@.
type ProfilesByUserTokenAPI =
  Summary "The profile a wallet-held user token owns"
    :> Description
         "The wallet direction: given the CIP-68 USER token a wallet holds, the profile it owns. \
         \\nThis is the only question a connected wallet can ask on its own. A profile is \
         \identified everywhere else here by its REFERENCE token \
         \(`<policy_id>.000643b0<hash>`, the one locked at the profiles validator with the \
         \datum), and the token that lands in the owner's wallet is the user half \
         \(`<policy_id>.000de140<hash>`). The two differ in their four-byte CIP-67 label and in \
         \nothing else. \
         \\nBefore this route a client had to do that swap in the browser -- enumerate \
         \`wallet.getAssets()`, filter on the policy id from `/status.attestation.policy_id`, \
         \rebuild the reference name, then call `/profiles/{id}` -- which is protocol knowledge no \
         \frontend should carry. Pass the wallet's asset class as it comes and this does the \
         \derivation. \
         \\nThe asset class must be `<policy_id_hex>.<token_name_hex>` whose name begins with the \
         \user label `000de140`. Anything else -- a reference token, an attestation id (CIP-67 \
         \private-use label 1), a dispute id (label 2), `lovelace`, or any unrelated asset -- is \
         \400 `invalid_asset_class`, never an empty result: \"no profile\" for an identifier that \
         \could not name one reads as \"you own no profile\". \
         \\n404 `profile_not_found` when the derivation succeeds and no projection carries the \
         \resulting id. That is the honest answer to \"this wallet holds a token of this policy \
         \that the registry has not projected yet\" and to \"this is not a profile token of this \
         \registry\" alike -- the policy id is not checked here, because the projection holds only \
         \one policy's rows and a foreign policy's token simply finds nothing. \
         \\nThe ANSWER IS THE CURRENT OWNER'S ONLY IN THE SENSE THAT THE TOKEN IS: the projection \
         \records no holding address (it is built from the registry's own UTxOs, not from wallet \
         \balances), so this says \"the profile whose user token this is\", which is what a wallet \
         \that just read its own assets already knows to be in its own hands."
    :> "profiles"
    :> "by-user-token"
    :> Capture "asset-class" Text
    :> Get '[JSON] AttestProfileRow

type ProfileAttestationsAPI =
  Summary "A profile's track record"
    :> Description
         "The attestations where this profile is the SUBJECT -- what others say about it, not what \
         \it has issued. `GET /attestations?issuer=<id>` is the other direction. \
         \\nACCEPTED FIRST, then newest, and there is no `order_by`: an unaccepted attestation is \
         \a claim the subject has not acknowledged, and sorting those to the top would make a page \
         \of unacknowledged claims look like a record. `sort_order` flips only the accepted/\
         \unaccepted grouping; within each group the rows stay newest-first. \
         \\n404 `profile_not_found` when the profile does not exist, rather than an empty page: \
         \\"no rows\" for an id that was mistyped reads as \"this profile has no record\"."
    :> "profiles"
    :> Capture "profile-id" ProfileRefAC
    :> "attestations"
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page AttestationRow)

type AttestationsAPI =
  Summary "Attestations"
    :> Description
         "Every attestation one profile has issued about another. One endpoint rather than a route \
         \per direction: `subject` is a track record, `issuer` is an issuance history, and both \
         \together is one actor's statements about another. \
         \\n`issuer` IS AN ISSUANCE HISTORY, so it excludes an unaccepted `credential_withdrawal`, \
         \and that is the one place the two directions are not symmetric. On the two credential \
         \kinds the issuer column is structural rather than authorial: the protocol forces issuer \
         \== subject on a binding record (`Mc1`), and it EXEMPTS a withdrawal from the rule that \
         \the issuer's user token be spent (`Mf`) -- deliberately, because the case a withdrawal \
         \exists for is a profile that claimed somebody else's credential, and that profile's \
         \token is held by whoever did it. So a withdrawal is minted on the named CREDENTIAL's \
         \proof alone and the profile it names never consented to it. Attributing it to that \
         \profile's issuance history would be this API asserting something the chain explicitly \
         \does not. \
         \\nConsent is `accepted`, the same signal every other kind uses: accepting requires the \
         \subject to spend its own user token, and subject == issuer here, so an ACCEPTED \
         \withdrawal is one the profile put its token behind and it stays in `issuer`. Nothing is \
         \hidden either way -- every withdrawal is reachable by `subject`, on \
         \/profiles/{id}/attestations and on /attestations/{id}, where the profile is the thing \
         \the record is about rather than its author. \
         \\n`date` is the ISSUANCE time and IS bounded by the minting transaction's validity \
         \interval. `claimed_period` is SELF-REPORTED and never chain-verified, which is why it is \
         \not a filter and not a sort key -- a range query over it would read as though the chain \
         \had checked it. Both of its bounds travel or neither. \
         \\n`accepted` is the subject's acknowledgement. It filters both ways and has no default, \
         \so the unfiltered list is the whole record including claims nobody has accepted. \
         \\n`date_from`/`date_to` bound `date`, inclusive; a reversed range is 400 \
         \`invalid_time_range` rather than an empty page. Default ordering is date descending."
    :> "attestations"
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParam "subject" ProfileRefAC
    :> QueryParam "issuer" ProfileRefAC
    :> QueryParams "kind" AttestationType
    :> QueryParam "accepted" Bool
    :> QueryParam "date_from" UTCTime
    :> QueryParam "date_to" UTCTime
    :> QueryParam "order_by" AttestationsOrderBy
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page AttestationRow)

type AttestationDetailAPI =
  Summary "Attestation"
    :> Description
         "One attestation with its disputes INLINE. Inline and not a second request for the reason \
         \/gov-action/{id} inlines its tallies: a client that fetches the challenges separately \
         \will render the attestation before they arrive, and an undisputed-looking attestation is \
         \exactly the wrong thing to show for a disputed one. \
         \\nAn upheld dispute is published BESIDE the attestation and never hides or deletes it, \
         \so `disputes` being non-empty is the whole signal -- read `verdict` on each, which is \
         \null while that dispute is open. \
         \\nAt most 50 disputes are inlined; a dispute costs a deposit, so more than that against \
         \one attestation is a funded adversary rather than a shape to expect, and an inline list \
         \has no offset to escape with. `GET /disputes?target=<id>` is the paged view. \
         \\nThe attestation and its disputes are read in ONE transaction, so they are the same \
         \snapshot. 404 `attestation_not_found` when the id names nothing."
    :> "attestations"
    :> Capture "attestation-id" AttestationAC
    :> Get '[JSON] AttestationDetailResponse

type DisputesAPI =
  Summary "Disputes"
    :> Description
         "Every dispute opened against an attestation. `resolved` is `verdict IS NOT NULL` and not \
         \a verdict value, because the column is null while a dispute is open -- so `resolved=\
         \false` is the open ones and `resolved=true` the CLOSED ones, which is three values and \
         \not two: `upheld` and `rejected` are the oracle admin's findings, and `expired` means \
         \nobody decided it and its deadline passed, so anyone was free to close it. A client that \
         \wants findings only must read the verdict value, not this flag. \
         \\n`deposit` is returned to the opener on EVERY outcome: there is no punitive verdict, so \
         \losing a dispute costs network fees and nothing else. \
         \\nOrdered by `opened_at`, newest first. There is no `order_by`: the list has one \
         \chronology, and a second ordering would be a control with no screen behind it."
    :> "disputes"
    :> QueryParam "limit" Int
    :> QueryParam "offset" Int
    :> QueryParam "target" AttestationAC
    :> QueryParam "resolved" Bool
    :> QueryParam "sort_order" SortOrder
    :> Get '[JSON] (Page DisputeRow)

-- | @GET \/disputes\/{dispute-id}@ — one dispute, by itself.
--
-- The list route above answers \"what is contested\", and @GET \/attestations\/{id}@ answers \"is
-- this attestation contested\". Neither answers \"show me THIS dispute\", which is what a
-- notification, a shared URL and a refresh button all need — and the two workarounds were
-- @\/disputes?target=…@ (which needs the attestation id as well, so a dispute URL had to carry
-- two) and the inline list on the attestation, which is capped at 50 rows and therefore cannot
-- address a dispute past the cap at all.
--
-- A bare 'DisputeRow' and not an envelope: it is one record, like @\/profiles\/{id}@. The
-- attestation it contests is @target@, so a client renders this beside a second request for the
-- attestation rather than having it inlined here — the inlining goes the other way round on
-- purpose, because an attestation shown without its challenges is the misleading direction and a
-- dispute shown without its target is merely incomplete.
type DisputeDetailAPI =
  Summary "Dispute"
    :> Description
         "One dispute by its asset class, `<policy_id>.<token_name_hex>`. \
         \\n`verdict` is null while the dispute is OPEN, and three values when it is closed: \
         \`upheld` and `rejected` are the oracle admin's findings, `expired` means the deadline in \
         \this dispute's own datum passed with nobody deciding it, at which point anyone was free \
         \to close it. `expired` is NOT a finding and must not be rendered as one. \
         \\n`deposit` is the lovelace the opener locked, returned on every outcome -- there is no \
         \punitive verdict, so losing a dispute costs network fees and nothing else. It is the \
         \amount THIS dispute recorded when it was opened, not the oracle's current price: \
         \repricing the protocol never moves an open dispute's deposit or its deadline. \
         \\n404 `dispute_not_found` when no projection carries that id, which includes an \
         \attestation id (the two wear different CIP-67 labels) and an id that exists on chain but \
         \has not been projected yet."
    :> "disputes"
    :> Capture "dispute-id" AttestationAC
    :> Get '[JSON] DisputeRow

handleGetProfiles ::
  Maybe Int ->
  Maybe Int ->
  [ProfileType] ->
  Maybe Bool ->
  Maybe Text ->
  Maybe ProfilesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page AttestProfileRow)
handleGetProfiles limit offset kinds claimed q orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  let filt =
        emptyAttestProfileFilter
          { attestProfileFilterKinds = kinds,
            attestProfileFilterClaimed = claimed,
            attestProfileFilterQ = q'
          }
  runRead
    ( listProfiles
        filt
        (fromMaybe ProfilesOrderByRegisteredAt orderBy, fromMaybe Desc sortOrder)
        bounds
    )

handleGetProfile :: ProfileRefAC -> QueryAppMonad AttestProfileRow
handleGetProfile pid = runRead (profileById pid) >>= maybe (throwApi ProfileNotFound) pure

handleGetProfilesByCredential :: Text -> Maybe Int -> Maybe Int -> QueryAppMonad (Page AttestProfileRow)
handleGetProfilesByCredential raw limit offset = do
  -- A 400 and not a 404: a CIP-105 id or a bare hash is a well-formed DRep identifier that this
  -- route cannot answer about, and answering "no profile claims it" would be a false negative
  -- dressed as a result. See 'canonicalGovCredential'.
  --
  -- `InvalidCredential` and no longer `InvalidDrepId`. The old pair was the measured defect: a
  -- perfectly good `cc_cold1…` was refused with "Not a DRep identifier", which is literally true
  -- and tells the caller nothing about what this route wanted. The new code's message names all
  -- three accepted HRPs, and `invalid_drep_id` keeps its own meaning on the governance routes,
  -- where a DRep identifier really is what was asked for.
  credential <- maybe (throwApi InvalidCredential) pure (canonicalGovCredential raw)
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  runRead
    ( listProfiles
        emptyAttestProfileFilter {attestProfileFilterCredential = Just credential}
        (ProfilesOrderByRegisteredAt, Asc)
        bounds
    )

-- | The profile a wallet-held CIP-68 user token owns.
--
-- Two refusals and they are different facts, which is why they are different statuses: an asset
-- class that is not a user token of a CIP-68 pair cannot name a profile at all (400), while one
-- that is may still name a profile this registry has no projection for (404).
handleGetProfileByUserToken :: Text -> QueryAppMonad AttestProfileRow
handleGetProfileByUserToken raw = do
  refAC <- maybe (throwApi InvalidAssetClass) pure (profileRefOfUserToken raw)
  runRead (profileById refAC) >>= maybe (throwApi ProfileNotFound) pure

handleGetProfileAttestations ::
  ProfileRefAC -> Maybe Int -> Maybe Int -> Maybe SortOrder -> QueryAppMonad (Page AttestationRow)
handleGetProfileAttestations pid limit offset sortOrder = do
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  -- ONE runRead, for the reason handleGetDRepDetail gives: the existence check and the page are
  -- one snapshot, so the 404 cannot be decided against a profile that the page then reads as gone.
  r <- runRead $ do
    mp <- profileById pid
    case mp of
      Nothing -> pure Nothing
      Just _ ->
        Just
          <$> listAttestations
            emptyAttestationRecordFilter {attestationRecordFilterSubject = Just pid}
            (subjectTrackRecordSortSpec, fromMaybe Desc sortOrder)
            bounds
  maybe (throwApi ProfileNotFound) pure r

handleGetAttestations ::
  Maybe Int ->
  Maybe Int ->
  Maybe ProfileRefAC ->
  Maybe ProfileRefAC ->
  [AttestationType] ->
  Maybe Bool ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Maybe AttestationsOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page AttestationRow)
handleGetAttestations limit offset subject issuer kinds accepted dateFrom dateTo orderBy sortOrder = do
  _ <- either throwApi pure (checkRanges dateFrom dateTo Nothing Nothing)
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  let filt =
        emptyAttestationRecordFilter
          { attestationRecordFilterSubject = subject,
            attestationRecordFilterIssuer = issuer,
            attestationRecordFilterKinds = kinds,
            attestationRecordFilterAccepted = accepted,
            attestationRecordFilterDateFrom = dateFrom,
            attestationRecordFilterDateTo = dateTo
          }
  runRead
    ( listAttestations
        filt
        ( attestationSortSpec (fromMaybe AttestationsOrderByDate orderBy),
          fromMaybe Desc sortOrder
        )
        bounds
    )

handleGetAttestation :: AttestationAC -> QueryAppMonad AttestationDetailResponse
handleGetAttestation aid =
  runRead (attestationById aid) >>= maybe (throwApi AttestationNotFound) pure

handleGetDisputes ::
  Maybe Int ->
  Maybe Int ->
  Maybe AttestationAC ->
  Maybe Bool ->
  Maybe SortOrder ->
  QueryAppMonad (Page DisputeRow)
handleGetDisputes limit offset target resolved sortOrder = do
  bounds <- either throwApi pure (normalizeLimitOffset jsonBounds limit offset)
  let filt = emptyDisputeFilter {disputeFilterTarget = target, disputeFilterResolved = resolved}
  runRead (listDisputes filt (fromMaybe Desc sortOrder) bounds)

handleGetDispute :: AttestationAC -> QueryAppMonad DisputeRow
handleGetDispute did = runRead (disputeById did) >>= maybe (throwApi DisputeNotFound) pure

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
    :<|> VotesAPI
    :<|> ActivityAPI
    :<|> SearchAPI
    :<|> DRepExplorerPageAPI
    :<|> DashboardPageAPI
    :<|> DelegationsAPI
    :<|> CommitteeAPI
    :<|> SPOsAPI
    :<|> TreasuryWithdrawalsAPI
    -- The attestation surface. `by-credential` and `by-user-token` precede the `{profile-id}`
    -- capture: see 'ProfilesByCredentialAPI'.
    :<|> ProfilesAPI
    :<|> ProfilesByCredentialAPI
    :<|> ProfilesByUserTokenAPI
    :<|> ProfileAttestationsAPI
    :<|> ProfileDetailAPI
    :<|> AttestationsAPI
    :<|> AttestationDetailAPI
    -- The list before the capture, for the same reason, although `/disputes` has no static
    -- sub-segment to collide with today.
    :<|> DisputesAPI
    :<|> DisputeDetailAPI

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
    :<|> votesServer
    :<|> activityServer
    :<|> searchServer
    :<|> handleGetDRepExplorerPage
    :<|> handleGetDashboardPage
    :<|> delegationsServer
    :<|> committeeServer
    :<|> sposServer
    :<|> treasuryWithdrawalsServer
    :<|> handleGetProfiles
    :<|> handleGetProfilesByCredential
    :<|> handleGetProfileByUserToken
    :<|> handleGetProfileAttestations
    :<|> handleGetProfile
    :<|> handleGetAttestations
    :<|> handleGetAttestation
    :<|> handleGetDisputes
    :<|> handleGetDispute

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
    -- 1.1.0: `/status` gained `attest_lag_seconds`. A MINOR bump because the field is optional and
    -- every 1.0.0 client keeps working — nothing was removed, renamed or made required. Independent
    -- of the app version by design (see CLAUDE.md): a client pins what it reads, not what we ship.
    -- 1.2.0, MINOR: `DisputeVerdict` gained `expired` (D-A). Additive for a reader — a client that
    -- knows the two findings still parses every document — but a client that SWITCHES on the value
    -- gains a case, and one that renders it as a finding is now wrong. A new enum value in a
    -- response is exactly the shape MINOR is for.
    -- 1.3.0, MINOR: `AttestationRow` gained `credential`. ADR 0003 stored the column and published
    -- nothing, so a `credential_claim` row was served with its entire content missing; adding an
    -- optional field breaks no 1.2.0 client.
    -- 1.4.0, MINOR: `/status` gained `attestation` (the projector's own report — state,
    -- last_sync_at, its own readiness, the policy it follows), plus `drep_distr_epoch`,
    -- `amber_lag_seconds`, `ready_max_lag_seconds` and `metrics_as_of_epoch` — four numbers `/ready`
    -- already decided with and the body did not publish (`CS-07`, `GV-23`). Additive: every 1.3.x
    -- client keeps working, and `attest_lag_seconds` stays beside the new block rather than being
    -- replaced by it. Three response HEADERS are new too (`X-Attest-Slot`,
    -- `X-Attest-Lag-Seconds`, `X-Attest-State`), present only where a projector exists.
    -- 1.3.1, PATCH: two descriptions stopped claiming something that was not true. "No second
    -- derivation" was false — the five DRep metrics come from a materialized view, which is one —
    -- and it was false in the direction that mattered: its denominator had drifted from the
    -- published formula (GV-03). No schema, field or status code changed.
    --
    -- 1.5.0, MINOR, and it is the largest of these bumps although nothing was removed:
    --
    --   * TWO ROUTES: `/profiles/by-user-token/{asset-class}` (the only question a connected wallet
    --     can ask — "which profile does this token I hold own") and `/disputes/{dispute-id}` (a
    --     dispute had no URL of its own, so a notification could not link to one).
    --   * `/profiles/by-credential/{credential}` ACCEPTS MORE: all three CIP-129 roles, not `drep`
    --     alone. Additive for every 1.4.x caller; its 400 changes code, from `invalid_drep_id` to
    --     the new `invalid_credential`, on inputs that were already 400s.
    --   * THREE NEW ERROR CODES — `invalid_credential`, `method_not_allowed`, `not_acceptable` —
    --     and three newly DECLARED statuses, 405, 406 and 500. The two router refusals were already
    --     being served; what is new is that they carry the documented `{code, message}` body
    --     instead of zero bytes.
    --   * `x-nullable` ON EVERY NULLABLE FIELD. The one change a generated client will notice
    --     most: 127 properties across 61 definitions were typed non-null and threw on the first
    --     `null`. No field was added, removed or renamed by it.
    --   * REAL `limit`/`offset` BOUNDS, per endpoint, in place of the Int64 range.
    --   * `issuer=` on `/attestations` no longer returns an unaccepted `credential_withdrawal`.
    --     The only behaviour change a 1.4.x client could see as a removal, and it is the fix: that
    --     row was the chain's statement about a profile, published as the profile's own.
    --
    -- 1.6.0, MINOR: `/votes` gains `is_final`, which is the parameter that makes the endpoint
    -- usable rather than a convenience — it keeps one row per (voter, action) and on preprod turns
    -- 3,244,723 rows into 931. Expressed the obvious way, `WHERE seq_last = 1`, that filter costs
    -- 7,058 ms, because a window column is not pushdown-safe; it reads the pre-aggregation instead
    -- and costs 2.4 ms. Also additive: `GET /disputes/{id}`, `GET /profiles/by-user-token/{id}`,
    -- `x-nullable` on every nullable field, the real `limit`/`offset` bounds, and a `{code, message}`
    -- body on the 405 and 406 the router used to answer empty.
    --
    -- 1.7.0, MINOR: `DisputeRow` gains `stale_after` — the dispute's own deadline, which was in the
    -- datum and published nowhere, so a client could only compute it from the oracle's CURRENT
    -- timeout and get the wrong date for any dispute opened before a retiming. And
    -- `/attestations/{id}` gains `level1_anchor` (ADR 0008): the treasury withdrawal or governance
    -- action an attestation points at, resolved at read time, with a `status` of `resolved`,
    -- `unresolved` or `malformed` — never hidden, because the datum permanently says the attestation
    -- is about that payment.
    -- 1.8.0, MINOR: `route_not_found`, the 404 for a path this API does not serve. It is additive in
    -- the only two ways a document can be — one more member of the `ErrorCode` enum, and a widened
    -- 404 description — and it closes the last refusal that answered with no body at all. The 404
    -- itself was already declared on every operation; what it said was "a well-formed request naming
    -- something that does not exist", which is the record-lookup case and not this one.
    --
    -- Also in 1.8.0, and additive in the same way: `unauthenticated`, `credentials_rejected` and
    -- `unsupported_media_type` appear in the published `ErrorCode` enum because the vocabulary is
    -- shared with interaction-api, which is the service that can return them. THIS document now says
    -- so, and says the same about `rate_limited` — reserved, no throttle built, no 429 declared on
    -- any operation. Four codes a client could have written an unreachable branch for; now four
    -- codes whose reachability is stated beside them. No route of this service changed.
    & info . Data.Swagger.version .~ "1.8.0"
    & info . Data.Swagger.description
      ?~ "Read-only queries over the Cardano governance record: DReps, governance actions, votes, \
         \delegations, the constitutional committee and treasury withdrawals. Every row comes from \
         \a view over cardano-db-sync — the only derived object is palmares.drep_metrics, a \
         \materialized view whose agreement with the published formulas is asserted by a test — and \
         \every published metric carries the id of the formula that produced it, resolvable at \
         \/metrics/formulas. \
         \\n\n**Paging.** Every `limit` and `offset` in this document carries the bound the server \
         \actually enforces. A `limit` outside its range is clamped silently and the applied value \
         \comes back in the response envelope; an `offset` above its maximum is refused with 400 \
         \`offset_too_large`. The one exception to the published `limit` ceiling is a CSV export: a \
         \request whose `Accept` is `text/csv` and nothing else raises the ceiling to "
      <> T.pack (show (boundMax csvBounds))
      <> " on the endpoints that produce it (see each route's `produces`), because the point of an \
         \export is to leave in one request. \
         \\n\n**Nullability.** A field absent from a definition's `required` list is a field this \
         \API sends as `null`, not one it omits, and it carries `x-nullable: true` so a generated \
         \client types it that way. The 15 such fields that are a bare `$ref` carry the key \
         \beside the reference, which a strict Swagger 2.0 reader is entitled to ignore; those are \
         \whole nested objects (`attestation` on /status, `verdict` on a dispute, `anchor` on a \
         \vote) rather than scalars inside a row."
    & info . license ?~ "Apache-2.0"
    & host .~ Nothing
    -- `addSharedSwaggerDescriptions`'s own Haddock says "call this in both interaction-api and
    -- query-api", and until now only interaction-api did — so the definition-level descriptions were
    -- absent from THIS document. Measured before adding it: of the seven rows, five name definitions
    -- this API does not emit at all (they are inlined, so the `at` lens is a silent no-op) and
    -- `GYAssetClass` gets its text from its own instance. The one that mattered is `AttestationType`,
    -- which this document DOES declare and which a client switches on to read `/attestations?kind=`.
    & addSharedSwaggerDescriptions
    -- ApiError and ErrorCode are declared EXPLICITLY, because nothing in the served API type
    -- mentions them: servant types the success body only, so swagger2 had no reason to emit
    -- either and the error contract was undiscoverable from the document. Every non-2xx body this
    -- service sends is an ApiError, and the codes are the thing a client branches on, so they
    -- belong in `definitions` and on the global responses below.
    --
    -- NO COUNT IN THIS SENTENCE, on purpose. It said "the 24 codes" and went stale twice without
    -- anything failing, because prose is the one place a number has no authority. The enum is
    -- derived from `Generic` over `ErrorCode` and is therefore complete by construction; the count
    -- is asserted where a wrong one breaks something — `UnitTests.GovDto` over
    -- `[minBound .. maxBound]`, and `scripts/check_swagger.sh` over the generated enum.
    & definitions %~ (<> execDeclare (declareSchemaRef (Proxy @ApiError)) mempty)
    & allOperations . responses . at 400
      ?~ Inline
        ( mempty
            { _responseDescription = "Invalid query parameters; the body carries a machine-readable `code`",
              _responseSchema = Just apiErrorRef
            }
        )
    & allOperations . responses . at 404
      ?~ Inline
        ( mempty
            { -- TWO facts under one status, and they are kept apart because a client acts on them
              -- differently: a different identifier fixes the first, and only different code fixes
              -- the second.
              _responseDescription =
                "Well-formed request naming something that does not exist (the `*_not_found` \
                \codes), or a path this API does not serve at all (`route_not_found`, from the \
                \router, before any lookup)",
              _responseSchema = Just apiErrorRef
            }
        )
    & allOperations . responses . at 405
      ?~ Inline
        ( mempty
            { _responseDescription = "That method is not served on this path",
              _responseSchema = Just apiErrorRef
            }
        )
    & allOperations . responses . at 406
      ?~ Inline
        ( mempty
            { _responseDescription =
                "No media type in `Accept` is one this route produces; compare `produces`",
              _responseSchema = Just apiErrorRef
            }
        )
    & allOperations . responses . at 503
      ?~ Inline
        ( mempty
            { _responseDescription = "Index not ready: too far behind, no ledger state, or the wrong network",
              _responseSchema = Just apiErrorRef
            }
        )
    -- 500 is DECLARED and 502 is NOT, which is a decision rather than an omission on either side.
    --
    -- A 500 is reachable here: it is the last resort warp installs for an uncaught exception
    -- (`Main` points that at 'Palmares.WebAPI.Errors.internalErrorResponse', so it carries this
    -- body like everything else). It is a bug and never a condition a client can fix — an
    -- unreachable database or a view a db-sync migration dropped is caught in
    -- 'QueryAppMonad.runRead' and served as 503 `db_unavailable`.
    --
    -- A 502 cannot come from this service. No `ErrorCode` maps to it and no handler raises one; a
    -- 502 reaching a client was produced by whatever proxy sits in front, with that proxy's own
    -- body, which this document has no business describing. Declaring it would repeat exactly the
    -- mistake `invalid_asset_class` was — publishing a case nothing can produce, which a client
    -- then writes a branch for and never exercises.
    & allOperations . responses . at 500
      ?~ Inline
        ( mempty
            { _responseDescription = "A bug here. `internal_error`, and never a condition the request can fix",
              _responseSchema = Just apiErrorRef
            }
        )
    -- The real paging bounds, per endpoint. See 'publishPageBounds'.
    & publishPageBounds
    & definitions . at "ErrorCode" . mapped . description
      ?~ "Every reason this API refuses or fails a request, as a stable snake_case tag. Branch on \
         \this, never on the message: the message is for people and may be reworded, the code is \
         \the contract. The status each one is served with is fixed -- the 400 group is a bad \
         \request, `method_not_allowed` is 405 and `not_acceptable` 406, the 404 group a \
         \well-formed request naming nothing, 429 a rate limit, the 503 group an index that is not \
         \ready yet, and internal_error a bug here. \
         \\n`method_not_allowed`, `not_acceptable` and `route_not_found` are the three that come \
         \out of the ROUTER rather than a handler, and all three used to be served with an empty \
         \body and no content type -- so a client calling `.json()` on a failure path threw a \
         \parse error instead of reading a code. `not_acceptable` is the reachable one in \
         \practice: six list routes produce `text/csv` and seven do not, and asking the wrong one \
         \for it is a real mistake with a real answer. \
         \\n`route_not_found` is the only 404 here that is NOT about a missing record -- nothing \
         \was looked up, the path matched no route. The `*_not_found` codes mean \"try another \
         \identifier\"; this one means the caller is built against a surface this server does not \
         \have. \
         \\n`invalid_credential` is /profiles/by-credential's own 400: a CIP-105 id, a bare hex \
         \hash, or an identifier whose header byte disagrees with its HRP. `invalid_drep_id` keeps \
         \its narrower meaning on the governance routes, where a DRep identifier is what was \
         \asked for. \
         \\n`invalid_asset_class` is /profiles/by-user-token's own 400 -- an asset class that is \
         \not the CIP-68 user half of a profile. The three asset-class CAPTURES \
         \(/profiles/{profile-id}, /attestations/{attestation-id}, /disputes/{dispute-id}) parse \
         \through Atlas's codec and answer `invalid_parameter` instead. \
         \\n\n**Four of these codes cannot be returned by THIS service, and the enum is shared \
         \rather than wrong.** `unauthenticated`, `credentials_rejected` and \
         \`unsupported_media_type` belong to the Interaction API: this surface is public and takes \
         \no request bodies, so no credential and no Content-Type of yours is ever consulted here. \
         \They are in one vocabulary because one middleware carries them on both services. \
         \\n`rate_limited` is **reserved and cannot be returned by either service today**: rate \
         \limiting is not implemented, nothing counts requests, and no operation in this document \
         \declares a 429 -- check `responses` on any route and you will not find one. Do not write \
         \a branch for it expecting traffic; the 429 is declared in the same release that ships the \
         \throttle. It is published only because withdrawing an already-published tag would be a \
         \breaking change for the clients that already switch exhaustively."
    & definitions . at "ApiError" . mapped . description
      ?~ "The body of every non-2xx response."
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
    & definitions . at "SearchResults" . mapped . description
      ?~ "Six groups, always present. `total` is across the whole match; each group's `items` is \
         \is capped at `limit_per_group`. A hit with no published text carries its identifier \
         \as its `title`."
    & definitions . at "CommitteeMemberStatus" . mapped . description
      ?~ "A committee member's standing, derived from committee_de_registration alone. Two values, \
         \not Koios's four: expiry is published beside it as expiration_epoch, because a member \
         \whose term ends in a future epoch is serving today."
    & definitions . at "SPOSummary" . mapped . description
      ?~ "One stake pool in the current voting-power distribution. `ticker` and \
         \`participation_rate` are null throughout F1 -- the first because db-sync's pool-metadata \
         \fetcher is disabled, the second because no spo_participation_rate_v1 exists in the \
         \metric catalog yet."
    & definitions . at "TreasuryWithdrawalRecord" . mapped . description
      ?~ "One treasury payment a governance action would make. `enacted_epoch` is the only \
         \authoritative enactment value db-sync has; `enacted_at` is epoch-only, with slot and \
         \tx_hash always null. `paid_heuristic` is a guess from (stake_address, spendable_epoch) \
         \and is ambiguous when one address receives two withdrawals in one epoch."
    & definitions . at "MetricFormula" . mapped . description
      ?~ "One published formula. `sql` is the statement the server actually executes, inlined \
         \from the same embed the query path reads, so the documented formula cannot drift \
         \from the served number. Exactly one of `sql_file` and `sql_object` is set, so every \
         \formula_id resolves to something a reader can go and look at. `params` names the \
         \positional placeholders in bind order."
    & definitions . at "PowerBucket" . mapped . description
      ?~ "One bucket of the voting-power histogram, half-open [lo, hi) in lovelace, with `hi` null \
         \on the open top bucket. Inclusive edges would double-count a DRep sitting exactly on \
         \one, and the counts would stop summing to the page total."
    & definitions . at "EpochParticipationPoint" . mapped . description
      ?~ "One epoch of DRep participation. `dreps_voted` counts voters and `votes_cast` counts \
         \votes; they differ by re-votes. The rate is null only when no DRep held power that \
         \epoch -- zero is a real reading and preprod epoch 311 has it."
    & definitions . at "AttestProfileRow" . mapped . description
      ?~ "One profile, as the attestation projections hold it. `credential` is the governance \
         \credential this profile CLAIMS, in its CIP-129 rendering -- a claim, not a proof: \
         \nothing on chain checks that the claimant controls it, and more than one profile may \
         \claim the same one. `credential_is_script` is that identifier's header byte decoded, so \
         \a consumer never has to parse bech32 to tell a key credential from a script one. `slot` \
         \is the only time a projection row carries, published raw because this service holds no \
         \slot configuration."
    & definitions . at "AttestationRow" . mapped . description
      ?~ "One attestation. `date` is the issuance time and IS bounded by the minting \
         \transaction's validity interval; `claimed_period` is SELF-REPORTED and never \
         \chain-verified, with both bounds present or neither. Rendering the two alike claims \
         \something the chain never said. `accepted` is the subject's acknowledgement."
    & definitions . at "DisputeRow" . mapped . description
      ?~ "One dispute against an attestation. `verdict` is null while the dispute is OPEN. An \
         \upheld dispute is published beside the attestation it contests and never hides or \
         \deletes it. `deposit` comes back to the opener on every outcome -- there is no punitive \
         \verdict, so losing one costs network fees and nothing else. \
         \\n`expired` is NOT a finding: it means the dispute's deadline passed with no verdict, at \
         \which point anyone may close it, and it must not be rendered the way `upheld` is. The \
         \deadline is per-dispute and fixed when it was opened, so repricing the protocol's \
         \timeout never moves it."
    & definitions . at "AttestationDetailResponse" . mapped . description
      ?~ "One attestation with its disputes inline, read in a single transaction so they are the \
         \same snapshot. At most 50 disputes travel; GET /disputes?target=<id> is the paged view."

-- | The page-size bounds each endpoint actually applies, by path and parameter name.
--
-- __Every entry is a reference to the same value the handler clamps with__, never a repeated
-- literal: @jsonBounds@, @activityBounds@, @epochSeriesBounds@, @searchGroupBounds@ and the three
-- dashboard pairs are the definitions in "Query.Common" and above, so a re-priced endpoint changes
-- one number and the document follows. That is the whole reason this is a table of names and not of
-- integers — the defect being fixed is a document whose numbers were not the server's.
--
-- The seven CSV-capable list routes are listed with their JSON bounds and not their CSV ones. A
-- @limit@ of 10,000 is reachable on them, but only for a request that asks for @text\/csv@ and
-- nothing else ('Query.Common.boundsFor'), and a generated client validating a JSON call against a
-- 10,000 ceiling would be told its request is fine and then silently served 200 rows. The higher
-- ceiling is stated once, in the document's own description, where \"which endpoints export CSV\"
-- is already answered by @produces@.
pageSizeBounds :: [(FilePath, Text, PageBounds)]
pageSizeBounds =
  -- The governance lists. All seven also export CSV; see the note above.
  [ ("/dreps", "limit", jsonBounds),
    ("/gov-actions", "limit", jsonBounds),
    ("/votes", "limit", jsonBounds),
    ("/delegations", "limit", jsonBounds),
    ("/spos", "limit", jsonBounds),
    ("/treasury-withdrawals", "limit", jsonBounds),
    ("/drep/{drep-id}/delegators", "limit", jsonBounds),
    -- JSON-only list routes.
    ("/drep/{drep-id}/updates", "limit", jsonBounds),
    ("/pages/drep-explorer", "limit", jsonBounds),
    ("/profiles", "limit", jsonBounds),
    ("/profiles/by-credential/{credential}", "limit", jsonBounds),
    ("/profiles/{profile-id}/attestations", "limit", jsonBounds),
    ("/attestations", "limit", jsonBounds),
    ("/disputes", "limit", jsonBounds),
    -- The four endpoints whose size is NOT the list default, which is the reason the table is
    -- per-endpoint rather than one global pair.
    ("/activity", "limit", activityBounds),
    ("/drep/{drep-id}/power", "limit", epochSeriesBounds),
    ("/search", "limit_per_group", searchGroupBounds),
    ("/pages/dashboard", "top_limit", dashboardTopBounds),
    ("/pages/dashboard", "closing_soon_limit", dashboardClosingSoonBounds),
    ("/pages/dashboard", "epochs", dashboardEpochsBounds)
  ]

-- | Replace the published @limit@\/@offset@ ranges with the ones the server enforces.
--
-- __What was there instead:__ @limit@ and @offset@ are declared @Int@, so swagger2 derived
-- @minimum: -9223372036854775808, maximum: 9223372036854775807@ for every one of them — the
-- @Int64@ range, on a parameter that is clamped to 200 and on an offset that is REFUSED above
-- 10,000. @docs\/usecases\/api-screen-map.md@ §5.11 records the consequence as a warning to the
-- frontend: \"Do not generate client validation from the schema\", which is a published contract
-- telling its only consumer not to read it.
--
-- __@limit@ clamps and @offset@ refuses, and the document now says which.__
-- 'Query.Common.normalizeLimitOffset' silently clamps a limit into range — both @0@ and @999@ have
-- an obvious intended meaning, and the APPLIED value travels back in the envelope — while an offset
-- past 'Query.Common.hardOffsetCeiling' is a 400, because clamping it would serve the wrong page to
-- a client with no way to notice. Two different behaviours at the edge, so two different
-- descriptions; the numbers themselves are the same values the handlers use.
--
-- The offset pass goes through @allOperations@ rather than the table, because the ceiling is one
-- number for the whole API and @\/activity@ — the one cursor-paged endpoint — declares no @offset@
-- at all, so there is nothing for it to match.
publishPageBounds :: Swagger -> Swagger
publishPageBounds s0 = foldl' withSize (s0 & allOperations . parameters . traversed . _Inline %~ withOffset) pageSizeBounds
  where
    withSize s (path_, pname, b) =
      s & paths . ix path_ . Data.Swagger.get . _Just . parameters . traversed . _Inline %~ sizeParam pname b

    sizeParam pname (PageBounds mx dflt) prm
      | prm ^. name == pname =
          prm
            & schema . _ParamOther . paramSchema . minimum_ ?~ 1
            & schema . _ParamOther . paramSchema . maximum_ ?~ fromIntegral mx
            & schema . _ParamOther . paramSchema . default_ ?~ toJSON dflt
            & description
              ?~ "Page size, "
                <> T.pack (show dflt)
                <> " when omitted. A value outside [1, "
                <> T.pack (show mx)
                <> "] is CLAMPED and never refused; the applied value comes back as `limit` in the \
                   \response envelope, so a clamp is visible rather than silent."
      | otherwise = prm

    withOffset prm
      | prm ^. name == "offset" =
          prm
            & schema . _ParamOther . paramSchema . minimum_ ?~ 0
            & schema . _ParamOther . paramSchema . maximum_ ?~ fromIntegral hardOffsetCeiling
            & schema . _ParamOther . paramSchema . default_ ?~ toJSON (0 :: Int)
            & description
              ?~ "Rows to skip. A negative value clamps to 0; above "
                <> T.pack (show hardOffsetCeiling)
                <> " the request is REFUSED with 400 `offset_too_large` rather than clamped, \
                   \because a clamped deep offset would serve a different page than the one asked \
                   \for. Use the cursor-paged /activity feed for a deep walk."
      | otherwise = prm

-- | The document as it is served and as it is written to disk.
--
-- __A 'Value' and not a 'Swagger', because @x-nullable@ is not expressible in swagger2's types__ —
-- see 'markNullableFields', which is the whole of the difference between this and 'apiSwagger'.
-- Both consumers go through it: @swaggerSchemaUIServerT@ takes any @ToJSON a@ (the schema endpoint's
-- own type is @Get '[JSON] Value@), and @Main@'s @--write-swagger-only@ encodes it. One producer, so
-- the committed file and the served document cannot differ — which is what the CI parity step
-- compares and what @scripts\/check_swagger.sh@ asserts against.
--
-- 'apiSwagger' stays a 'Swagger' and stays exported: it is the value the lens chain builds and the
-- one a @ToSchema@-level test can inspect.
apiSwaggerDoc :: Value
apiSwaggerDoc = markNullableFields (toJSON apiSwagger)

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") QueryAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwaggerDoc

-- | A @$ref@ to the 'ApiError' definition the swagger above declares.
apiErrorRef :: Referenced Schema
apiErrorRef = Ref (Reference "ApiError")

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
--
-- 'refusedRequestMiddleware' is applied INNERMOST, immediately around @serveWithContext@, for the
-- mirror-image reason: it has to see the router's own 405 and 406 while they still carry no
-- content type — which is the only thing that tells them from a 4xx a handler built — and the JSON
-- body it substitutes then travels back out through 'freshnessMiddleware' and CORS like any other
-- response, so a browser gets the chain-point headers and the @Access-Control-Allow-Origin@ on a
-- refusal too. interaction-api wraps @provideOptions@ instead of sitting inside it; the two are
-- equivalent in effect, because every response @provideOptions@ produces itself is a 200.
mkWebApp :: CorsConfig -> IO (Maybe Freshness, Maybe AttestationStatus) -> QueryAppContext -> Application
mkWebApp corsCfg readFresh ctx =
  mkCorsMiddleware corsCfg $
    freshnessMiddleware readFresh $
      provideOptions proxyPublicAPI $
        refusedRequestMiddleware $
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
-- MOVED to "Palmares.WebAPI.Errors", because interaction-api had no formatters at all and a value
-- defined privately here could not be shared: a malformed JSON body on any of its twelve POST routes
-- came back as plain text with no `code`. One definition, in the library that owns the vocabulary.
