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
import Data.Swagger.Declare (execDeclare)
import Data.Text (Text)
import Network.Wai (Application)
import Network.Wai.Middleware.Servant.Options (provideOptions)
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types
  ( ActivityEventType,
    ActivitySource,
    AnchorStatus,
    DRepId (..),
    drepIdHex,
    DRepStatus (..),
    DRepUpdateKind,
    GovActionId (..),
    GovActionState (..),
    GovActionType,
    SearchKind,
    Vote,
    VoterRole (..),
  )
import Palmares.DomainTypes.Core.Ids (anyVoterIdHex)
import Palmares.DomainTypes.Transfer.Filters
  ( DelegationFilter (..),
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
  ( DelegationsOrderBy (..),
    DelegatorsOrderBy (..),
    DRepsOrderBy (..),
    GovActionsOrderBy (..),
    SortOrder (..),
    SPOsOrderBy (..),
    TreasuryWithdrawalsOrderBy (..),
    VotesOrderBy (..),
  )
import Palmares.DomainTypes.Transfer.QueryResponses
  ( ActivityRow,
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
    GovActionAnchorContent,
    GovActionDetailResponse (..),
    GovActionSummary,
    ParamChangeRow (..),
    ProposerSummary,
    SearchResults,
    SPOSummary,
    StatusResponse (..),
    TreasuryWithdrawalRecord,
    TreasuryWithdrawalRow,
    VoteRecord,
    VoteTally (..),
  )
import Palmares.Metrics.Catalog (MetricFormula, resolvedMetricCatalog, retentionWindowEpochs)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.CSV (CSV)
import Data.Text qualified as T
import Palmares.WebAPI.Envelope (ApiError, ErrorCode (..), Page (..), errorCodeFromText, errorCodeToHttpStatus)
import Palmares.WebAPI.Errors (errorCodeFromParserMessage, mkServantErr)
import Query.Common
  ( PageBounds (..),
    activityBounds,
    boundsFor,
    checkRanges,
    epochSeriesBounds,
    jsonBounds,
    normalizeLimitOffset,
    normalizeQ,
    searchGroupBounds,
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
import Palmares.WebAPI.ServiceProbe (ServiceProbe, ServiceProbeStatus)
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
  Maybe VotesOrderBy ->
  Maybe SortOrder ->
  QueryAppMonad (Page VoteRecord)
handleGetVotes accept limit offset roles voterIds gaIds verdicts gaTypes anchorStatus from to fromEpoch toEpoch q orderBy sortOrder = do
  q' <- either throwApi pure (normalizeQ q)
  _ <- either throwApi pure (checkRanges from to fromEpoch toEpoch)
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
            voteFilterFrom = from,
            voteFilterTo = to,
            voteFilterFromEpoch = fromEpoch,
            voteFilterToEpoch = toEpoch,
            voteFilterQ = q'
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
handleGetDelegations accept limit offset drepIds stakeAddrs isCurrent from to minLovelace orderBy sortOrder = do
  _ <- either throwApi pure (checkRanges from to Nothing Nothing)
  bounds <- either throwApi pure (normalizeLimitOffset (boundsFor accept) limit offset)
  let filt =
        emptyDelegationFilter
          { delegationFilterDrepHex = hexes,
            delegationFilterReservedTargets = reserved,
            delegationFilterStakeAddresses = stakeAddrs,
            delegationFilterIsCurrent = fromMaybe True isCurrent,
            delegationFilterFrom = from,
            delegationFilterTo = to,
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

handleGetDashboardPage ::
  Maybe Int -> Maybe Int -> Maybe Int -> QueryAppMonad DashboardPageResponse
handleGetDashboardPage topLimit closingSoonLimit epochsParam = do
  -- The three sizes are clamped by the SAME helper every page uses, so they clamp silently rather
  -- than refusing, and the applied value is the one the response was built from.
  (topLim, _) <- either throwApi pure (normalizeLimitOffset (PageBounds 50 10) topLimit Nothing)
  (soonLim, _) <- either throwApi pure (normalizeLimitOffset (PageBounds 20 5) closingSoonLimit Nothing)
  (epochs, _) <- either throwApi pure (normalizeLimitOffset (PageBounds 100 20) epochsParam Nothing)
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
              dashboardTotalDreps = n DRepActive + n DRepInactive,
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
    & info . Data.Swagger.version .~ "1.0.0"
    & info . Data.Swagger.description
      ?~ "Read-only queries over the Cardano governance record: DReps, governance actions, votes, \
         \delegations, the constitutional committee and treasury withdrawals. Every row comes from \
         \a view over cardano-db-sync — there is no projection table and no second derivation — and \
         \every published metric carries the id of the formula that produced it, resolvable at \
         \/metrics/formulas."
    & info . license ?~ "Apache-2.0"
    & host .~ Nothing
    -- ApiError and ErrorCode are declared EXPLICITLY, because nothing in the served API type
    -- mentions them: servant types the success body only, so swagger2 had no reason to emit
    -- either and the error contract was undiscoverable from the document. Every non-2xx body this
    -- service sends is an ApiError, and the 24 codes are the thing a client branches on, so they
    -- belong in `definitions` and on the three global responses below.
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
            { _responseDescription = "Well-formed request naming something that does not exist",
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
    & definitions . at "ErrorCode" . mapped . description
      ?~ "Every reason this API refuses or fails a request, as a stable snake_case tag. Branch on \
         \this, never on the message: the message is for people and may be reworded, the code is \
         \the contract. The status each one is served with is fixed -- the 400 group is a bad \
         \request, the 404 group a well-formed request naming nothing, 429 a rate limit, the 503 \
         \group an index that is not ready yet, and internal_error a bug here."
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

swaggerServer :: ServerT (SwaggerSchemaUI "swagger-ui" "swagger-api.json") QueryAppMonad
swaggerServer = swaggerSchemaUIServerT apiSwagger

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
    -- 'errorCodeFromParserMessage' carries the reason it is not a plain decode of the whole
    -- string: servant wraps a query parameter's message and passes a capture's through.
    fromParserMessage _ _ msg =
      let code = errorCodeFromParserMessage msg
       in mkServantErr (errorCodeToHttpStatus code) code
