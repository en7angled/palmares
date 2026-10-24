{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The governance read path: how every query reaches the database, and the freshness contract.
--
-- Two plumbing rules every route family inherits, and both are here rather than repeated per
-- handler:
--
-- 1. __One transaction per request, at @RepeatableRead@__ ('runGovRead'). db-sync declares
--    @-- noreference@ on the governance foreign keys, so a composite read made of several
--    statements can observe a dangling id while a rollback commits underneath it. At
--    @ReadCommitted@ — persistent's default — a page could show a vote on an action that the
--    next statement reports as never proposed.
--
-- 2. __One JSON column per statement__ ('queryJson'). Each @SELECT@ projects exactly one
--    @row_to_json(...)::text@ whose keys are the DTO's snake_case wire names, and the DTO's own
--    @FromJSON@ decodes it. A renamed or dropped view column then fails at the boundary NAMING
--    the field, instead of shifting a positional decode one column to the left and publishing
--    the wrong number under the right name.
--
-- Every timestamp inside those objects is written @AT TIME ZONE 'UTC'@, which turns db-sync's
-- bare @timestamp@ into a @timestamptz@ that renders with a @+00:00@ offset. Without it the
-- value reaches a client with no zone at all and @FromJSON UTCTime@ rejects it. That cast is
-- owned here, in the projection, never in the views: @palmares.sync_state@ ships @tip_time@ as
-- the bare timestamp it reads, and only @lag_seconds@ is pre-computed there.
module Query.Gov
  ( -- * Plumbing
    runGovRead,
    queryJson,
    queryJson1,

    -- * Readiness
    ReadyInputs (..),
    readyVerdict,
    attestStatusOf,
    readyMaxLagDefault,
    amberLagDefault,
    readyMaxLagFromEnv,
    amberLagFromEnv,
    expectedNetworkFromEnv,

    -- * Freshness
    Freshness (..),
    freshnessPollMsFromEnv,
    readFreshness,
    startFreshnessPoll,
    freshnessMiddleware,
    syncStatusOf,

    -- * Queries
    freshnessQuery,
    epochParamsQuery,
    metricsAsOfEpochQuery,

    -- * DReps
    drepSortSpec,
    drepWhere,
    listDReps,

    -- * The DRep profile
    resolveDRepHex,
    resolveReservedDRep,
    drepSummaryByIdQuery,
    drepMetricsQuery,
    listEpochPower,
    delegatorStatsQuery,
    listDelegators,
    listDRepUpdates,
    anchorContentQuery,
    delegatorOrderColumn,

    -- * Governance actions
    govActionSortSpec,
    govActionWhere,
    listGovActions,

    -- * The governance action page
    resolveGovAction,
    govActionByIdQuery,
    listTallies,
    listWithdrawals,
    paramChangeColumns,
    proposerQuery,
    govActionAnchorQuery,
    thresholdValueAt,

    -- * Votes
    voteSortSpec,
    voteWhere,
    VoteJoins (..),
    voteJoinsFor,
    voteBaseFrom,
    voteBaseWhere,
    voteBaseSortSpec,
    voteIdentityJoins,
    listVotes,
    -- * Delegations
    delegationSortSpec,
    delegationOuterSortSpec,
    delegationFrom,
    delegationWhere,
    delegationIsCurrentExpr,
    listDelegations,

    -- * The committee
    getCommittee,

    -- * SPOs
    spoSortSpec,
    spoFrom,
    spoWhere,
    listSPOs,

    -- * Treasury withdrawals
    withdrawalSortSpec,
    withdrawalFrom,
    withdrawalWhere,
    listTreasuryWithdrawals,

    -- * GET /search
    searchActionId,
    searchQuery,

    -- * GET \/activity
    parseCursor,
    FeedDir (..),
    activityWindows,
    activityWhere,
    listActivity,

    -- * The page composites
    drepStatusExpr,
    -- | Exported for one test: that it interpolates 'drepStatusExpr' instead of repeating it. The
    -- duplicate it used to hold is the defect that expression exists to prevent, and nothing but a
    -- test on the statement text can prove the copy is gone.
    searchSql,
    effectiveDRepStatus,
    registeredDRepStatuses,
    DRepFacets (..),
    drepFacetsSql,
    drepFacetsQuery,
    DashboardTotals (..),
    dashboardTotalsQuery,
    listEpochParticipation,
  )
where

import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isDigit, isHexDigit)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.Persist.Sql
  ( ConnectionPool,
    IsolationLevel (RepeatableRead),
    PersistValue,
    Single (..),
    SqlPersistT,
    rawExecute,
    rawSql,
    runSqlPoolWithIsolation,
    toPersistValue,
  )
import Deriving.Aeson
import Network.HTTP.Types.Header (Header)
import Network.Wai (Middleware, mapResponseHeaders)
import Palmares.DomainTypes.Core.Ids (anyVoterIdHex, parseGovActionIdCip129)
import Palmares.DomainTypes.Core.Types
  ( AnchorStatus,
    DRepStatus (..),
    GovActionId (..),
    GovActionState,
    GovActionType,
    SearchKind (..),
    Vote (..),
    VoterRole (..),
  )
import Palmares.DomainTypes.Transfer.Filters
  ( DRepFilter (..),
    DelegationFilter (..),
    GovActionFilter (..),
    GovActivityFilter (..),
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
import Data.Int (Int64)
import Palmares.DomainTypes.Transfer.QueryResponses
  ( ActivityCursor (..),
    ActivityRow (..),
    AnchorContent,
    AttestationStatus (..),
    CommitteeResponse,
    DelegationRecord,
    DelegatorRow,
    DelegatorStats,
    DRepMetrics,
    DRepSummary,
    DRepUpdateRow,
    EpochParamsSummary (..),
    EpochParticipationPoint,
    EpochPowerPoint,
    GovActionAnchorContent,
    GovActionSummary,
    PowerBucket,
    ProposerSummary,
    SearchResults,
    SPOSummary,
    SyncStatus (..),
    TreasuryWithdrawalRecord,
    TreasuryWithdrawalRow,
    VoteRecord,
    VoteTally,
  )
import Palmares.Metrics.Catalog (lookupMetricSql)
import Palmares.Storage (AttestSyncState (..), attestSyncStateRow)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.Envelope (Cursor (..), ErrorCode (..), Page (..))
import Query.Common (Limit, Offset, SortSpec (..), likePat, orderClause)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Run a governance read in one @RepeatableRead@ transaction. See rule 1 in the module header.
runGovRead :: ConnectionPool -> SqlPersistT IO a -> IO a
runGovRead pool act =
  runSqlPoolWithIsolation (setReadTimeout >> act) pool RepeatableRead
  where
    -- Interpolated, not bound: SET's argument is not a value expression, so a placeholder there is
    -- at best driver-specific. 'readTimeoutMs' is a compile-time constant of this module, so there
    -- is nothing a caller could put in it.
    setReadTimeout =
      rawExecute ("SET LOCAL statement_timeout = " <> T.pack (show readTimeoutMs)) []

-- | The ceiling on one read, in milliseconds.
--
-- WITHOUT it a pathological query has no end: the client waits until it gives up, and the pool
-- connection stays busy for as long as PostgreSQL keeps working — which it does even after the
-- client disconnects. MEASURED, and this is why it exists rather than as a precaution: a
-- @\/votes?voter_role=constitutional_committee@ page over preprod's 3,243,802 committee votes was
-- still running after 166 seconds, and every abandoned attempt left ANOTHER backend grinding, so
-- three aborted requests had three full scans competing for a container limited to 0.75 of a CPU.
-- A query that is cancelled frees its connection; one that is abandoned does not.
--
-- 30 seconds, and a read that needs longer is a defect to fix rather than a wait to serve: the
-- slowest legitimate page measured in this service is the activity ladder's last rung at 4.6 s.
-- The cancellation arrives as SQLSTATE 57014 and 'QueryAppMonad.runRead' already turns any
-- SqlError into a 503 @db_unavailable@ — the honest answer for "not now", and a definite one,
-- which is the point.
readTimeoutMs :: Int64
readTimeoutMs = 30_000

-- | Run a statement that projects exactly one @row_to_json(...)::text@ column and decode each row.
--
-- A decode failure is an @error@ rather than a @Left@ on purpose: it means the view and the DTO
-- disagree, which is a deployment fault, not a client's. Failing loudly with the aeson message —
-- which names the offending key — is what makes it a two-minute fix instead of a hunt for which
-- field went null.
queryJson :: (FromJSON a) => Text -> [PersistValue] -> SqlPersistT IO [a]
queryJson sql params = do
  rows <- rawSql sql params
  pure (map decode1 rows)
  where
    decode1 (Single (txt :: Text)) =
      case eitherDecodeStrict (TE.encodeUtf8 txt) of
        Right a -> a
        Left e -> error ("Query.Gov.queryJson: view and DTO disagree: " <> e <> "\n  row: " <> BS8.unpack (TE.encodeUtf8 (T.take 2000 txt)))

-- | The single-row form. 'Nothing' when the statement returned no row.
queryJson1 :: (FromJSON a) => Text -> [PersistValue] -> SqlPersistT IO (Maybe a)
queryJson1 sql params = do
  rows <- queryJson sql params
  pure $ case rows of
    (a : _) -> Just a
    [] -> Nothing

-- ---------------------------------------------------------------------------------------------

-- * Readiness

-- | Everything @\/ready@ decides on.
--
-- A record rather than six arguments so the verdict can be tested without a database, which is
-- the only way these four rules get tested at all: reproducing \"db-sync is 301 seconds behind\"
-- against a live stack is not something a test suite can arrange.
data ReadyInputs = ReadyInputs
  { readyDbOk :: Bool,
    readyLagSeconds :: Int,
    readyEpochNo :: Int,
    readyDrepDistrEpoch :: Int,
    readyNetworkName :: Text,
    readyExpectedNetwork :: Text,
    -- | The attestation projector's lag in seconds, or 'Nothing' for no evidence either way. See
    -- 'startFreshnessPoll' for why absence is not a failure.
    readyAttestLagSeconds :: Maybe Int,
    -- | The projector's own word for what it is doing, when it has written one — `CS-07`.
    readyAttestState :: Maybe Text,
    -- | How long ago the projector last wrote its row, in seconds.
    --
    -- This is the evidence the cursor lag cannot give: a projector that DIED leaves a cursor that
    -- stops moving, and if db-sync has also stopped there is no lag at all to notice. A report that
    -- stopped arriving is unambiguous.
    readyAttestReportAgeSeconds :: Maybe Int
  }
  deriving (Show, Eq)

-- | @Nothing@ means ready. Otherwise the code to serve with 503.
--
-- The lag ceiling is an ARGUMENT rather than the 'readyMaxLagDefault' constant, because
-- @PALMARES_READY_MAX_LAG_SECONDS@ has to be able to change it; a constant inside the verdict
-- would make the env var decorative. The default is still the documented value and is what every
-- test passes.
--
-- Four checks, and each one is a way the service can be running perfectly and still unable to
-- answer honestly:
--
--   * no database — nothing is known;
--   * the tip is stale — every number would be yesterday's, served as today's;
--   * no DRep stake distribution for the current or previous epoch — the ledger produces it one
--     epoch behind, so @epoch_no - 1@ is normal and anything older means @ledger: enable@ is not
--     taking, which makes every voting-power number missing rather than wrong;
--   * the wrong network — the single worst failure available to this service, because it would
--     answer every question confidently with another chain's data;
--   * the attestation projector is behind — the four above are all about db-sync's governance
--     index, and a service perfectly current on all of them can still be serving attestation
--     routes off a projection that stopped advancing. @Nothing@ is NO EVIDENCE and passes, which is
--     the one asymmetry here: a governance-only deployment runs no projector, and a probe that
--     failed on absence would take it out of rotation for doing nothing wrong. This check reads the
--     SUM of the two lags, because the projector's own number is measured against db-sync's cursor
--     rather than the tip; see the guard itself.
readyVerdict :: Int -> ReadyInputs -> Maybe ErrorCode
readyVerdict maxLag ReadyInputs {..}
  | not readyDbOk = Just DbUnavailable
  | readyLagSeconds > maxLag = Just IndexerBehind
  | readyDrepDistrEpoch < readyEpochNo - 1 = Just IndexerBehind
  | readyNetworkName /= readyExpectedNetwork = Just NotReady
  -- SUMMED, because the two lags have different reference points. `readyLagSeconds` is seconds
  -- between db-sync's newest block and now; `readyAttestLagSeconds` is the projector's distance
  -- from THAT block, not from the tip (`startFreshnessPoll` passes `freshSlot f` as the reference,
  -- and `palmares.sync_state.slot_no` is `public.block`'s newest row). Comparing the second to an
  -- absolute ceiling made the projector's real allowance `maxLag + dbSyncLag`: db-sync 250 s behind
  -- inside a 300 s ceiling let a projector 500 s behind the tip pass. The sum is the projector's
  -- absolute staleness, which is what the ceiling is supposed to bound. Reaching this guard already
  -- implies `readyLagSeconds <= maxLag`, so this is strictly stronger than the check it replaces
  -- and can only ever turn a PASS into a 503 — never the reverse.
  | Just lag <- readyAttestLagSeconds, readyLagSeconds + lag > maxLag = Just IndexerBehind
  -- `CS-07`. Both guards fire only when the projector HAS written a row, so a governance-only
  -- deployment is untouched — absence still passes, for the reason the record's field says.
  --
  -- A projector whose last tick raised is not serving honest pages: whatever it could not apply is
  -- missing, and `attest_dead_letter` says what.
  | readyAttestState == Just "error" = Just IndexerBehind
  -- And a projector that stopped REPORTING is dead, whatever its cursor says. This is the case the
  -- lag guard above cannot see: a dead projector plus a stalled db-sync is two frozen numbers whose
  -- difference is zero.
  | Just age <- readyAttestReportAgeSeconds, age > maxLag = Just IndexerBehind
  -- `syncing` is deliberately NOT red. A projector mid-pass is a healthy service answering honest
  -- partial pages, and `/status.attestation.state` plus `X-Attest-State` are how a client knows to
  -- say so. Red here would take a fresh deployment's governance routes — which are complete and
  -- correct — out of rotation for the hours the attestation backfill takes.
  | otherwise = Nothing

-- | The lag at which @\/ready@ turns red: 300 s, about thirteen preprod blocks.
readyMaxLagDefault :: Int
readyMaxLagDefault = 300

-- | The lag at which a UI should warn: 120 s.
--
-- A BAND, never the probe. If this were the readiness threshold, a normal gap between blocks
-- would take the service out of rotation; as a band it lets a dashboard say \"catching up\" while
-- the service keeps answering.
amberLagDefault :: Int
amberLagDefault = 120

-- | @PALMARES_READY_MAX_LAG_SECONDS@, defaulting to 'readyMaxLagDefault'.
readyMaxLagFromEnv :: IO Int
readyMaxLagFromEnv = intFromEnv "PALMARES_READY_MAX_LAG_SECONDS" readyMaxLagDefault

-- | @PALMARES_AMBER_LAG_SECONDS@, defaulting to 'amberLagDefault'.
amberLagFromEnv :: IO Int
amberLagFromEnv = intFromEnv "PALMARES_AMBER_LAG_SECONDS" amberLagDefault

-- | @PALMARES_FRESHNESS_POLL_MS@, defaulting to 5000.
freshnessPollMsFromEnv :: IO Int
freshnessPollMsFromEnv = intFromEnv "PALMARES_FRESHNESS_POLL_MS" 5000

-- | @PALMARES_NETWORK_NAME@, defaulting to @preprod@.
--
-- The expected value @\/ready@ compares @meta.network_name@ against. It has a default because a
-- misconfigured instance should fail its probe rather than refuse to start — an operator reading
-- \"not_ready: wrong network\" learns more than one reading a boot error.
expectedNetworkFromEnv :: IO Text
expectedNetworkFromEnv = maybe "preprod" T.pack <$> lookupEnv "PALMARES_NETWORK_NAME"

intFromEnv :: String -> Int -> IO Int
intFromEnv name def = do
  mv <- lookupEnv name
  pure $ case mv >>= readMaybe of
    Just n | n > 0 -> n
    _ -> def

-- ---------------------------------------------------------------------------------------------

-- * Freshness

-- | The tip, as the last successful poll saw it.
--
-- @drep_distr_epoch@ and @network_name@ are nullable because they are subqueries in
-- @palmares.sync_state@: an empty @drep_distr@ or an empty @meta@ yields NULL rather than no row,
-- and both are conditions @\/ready@ must report rather than crash on.
data Freshness = Freshness
  { freshEpoch :: Int,
    freshSlot :: Integer,
    freshBlockTime :: UTCTime,
    freshLagSeconds :: Int,
    freshDrepDistrEpoch :: Maybe Int,
    freshNetworkName :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "fresh", CamelToSnake]] Freshness

-- | The one row of @palmares.sync_state@, as one JSON object.
freshnessQuery :: SqlPersistT IO (Maybe Freshness)
freshnessQuery =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT s.epoch_no AS epoch, s.slot_no AS slot, \
    \         (s.tip_time AT TIME ZONE 'UTC') AS block_time, \
    \         s.lag_seconds, s.drep_distr_epoch, s.network_name \
    \  FROM palmares.sync_state s \
    \) x"
    []

-- | The latest protocol parameters, as one JSON object.
--
-- The LATEST row rather than the tip epoch's, because @epoch_param@ is written per epoch and the
-- open epoch's row may not exist yet; serving no parameters at all would make every tally on
-- @\/status@ unauditable for the first blocks of an epoch.
--
-- The threshold lists are built as @[name, value]@ pairs with db-sync's own column names, so a
-- reader can look any of them up in @palmares.thresholds@ and check our arithmetic.
-- | The epoch @palmares.drep_metrics@ was last refreshed for — `GV-23`.
--
-- One scalar off the matview, which check 070 asserts holds exactly one distinct value: every metric
-- on a DRep response is "as of" this epoch, and it trails @governance.epoch@ by up to the refresh
-- interval. A reader comparing a metric against a vote cast this epoch needs to know which.
--
-- 'Nothing' when the matview is empty, which is a database with no blocks rather than an error.
metricsAsOfEpochQuery :: SqlPersistT IO (Maybe Int)
metricsAsOfEpochQuery = do
  rows <- rawSql "SELECT as_of_epoch FROM palmares.drep_metrics LIMIT 1" []
  pure $ case rows of
    (Single e : _) -> Just e
    [] -> Nothing

epochParamsQuery :: SqlPersistT IO (Maybe EpochParamsSummary)
epochParamsQuery =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT t.epoch_no AS epoch, \
    \         t.gov_action_lifetime, t.gov_action_deposit, t.drep_deposit, t.drep_activity, \
    \         t.committee_min_size, t.committee_max_term_length, \
    \         json_build_array( \
    \           json_build_array('dvt_motion_no_confidence',  t.dvt_motion_no_confidence), \
    \           json_build_array('dvt_committee_normal',      t.dvt_committee_normal), \
    \           json_build_array('dvt_committee_no_confidence', t.dvt_committee_no_confidence), \
    \           json_build_array('dvt_update_to_constitution', t.dvt_update_to_constitution), \
    \           json_build_array('dvt_hard_fork_initiation',   t.dvt_hard_fork_initiation), \
    \           json_build_array('dvt_p_p_network_group',      t.dvt_p_p_network_group), \
    \           json_build_array('dvt_p_p_economic_group',     t.dvt_p_p_economic_group), \
    \           json_build_array('dvt_p_p_technical_group',    t.dvt_p_p_technical_group), \
    \           json_build_array('dvt_p_p_gov_group',          t.dvt_p_p_gov_group), \
    \           json_build_array('dvt_treasury_withdrawal',    t.dvt_treasury_withdrawal) \
    \         ) AS drep_thresholds, \
    \         json_build_array( \
    \           json_build_array('pvt_motion_no_confidence',   t.pvt_motion_no_confidence), \
    \           json_build_array('pvt_committee_normal',       t.pvt_committee_normal), \
    \           json_build_array('pvt_committee_no_confidence', t.pvt_committee_no_confidence), \
    \           json_build_array('pvt_hard_fork_initiation',   t.pvt_hard_fork_initiation), \
    \           json_build_array('pvtpp_security_group',       t.pvtpp_security_group) \
    \         ) AS pool_thresholds \
    \  FROM palmares.thresholds t \
    \  ORDER BY t.epoch_no DESC \
    \  LIMIT 1 \
    \) x"
    []

-- | Read the current freshness. 'Nothing' means the last poll failed or none has run yet.
readFreshness :: TVar (Maybe Freshness) -> IO (Maybe Freshness)
readFreshness = readTVarIO

-- | Poll @palmares.sync_state@ into a 'TVar' forever, and hand back the 'TVar'.
--
-- ONE poller, read by @\/ready@, @\/status@ and 'freshnessMiddleware' alike, so the service has
-- exactly one definition of \"how fresh are we\" and the hot path adds no query. The middleware
-- stamps every response, so without the cache the headers would cost a round trip per request.
--
-- A failed poll leaves the previous value in place rather than clearing it: one dropped
-- connection should not make the whole service report itself unready. The poll is seeded
-- synchronously before the thread starts, so the first request never sees an empty 'TVar' on a
-- healthy database.
-- __The second 'TVar' is the ATTESTATION PROJECTOR's own report__, and it is a separate reading
-- because it comes from a separate service. Everything above is about db-sync's governance index;
-- none of it says anything about whether @attest-sync@ is still running. Without it a probe could
-- report @ready@ while every attestation route served a projection frozen hours ago — the one
-- failure this surface cannot detect from its own data.
--
-- @Nothing@ means NO EVIDENCE, not \"fine\": the table is absent, or unreadable, or the projector
-- has never written a row. It is deliberately not a readiness failure, because a governance-only
-- deployment runs no projector and would otherwise be permanently out of rotation.
--
-- __It reads the ROW and no longer the cursor — `CS-07`.__ The paragraph that stood here said
-- absence was silent and named the follow-up: a field on the @\/status@ body, a Swagger bump and an
-- update to @scripts\/check_swagger.sh@. That is what landed. The cursor is written only after a
-- window has been applied in full, so it could not distinguish \"never started\" from \"caught
-- up\"; the projector now writes @attest_sync_state@ on every tick, carrying its own @state@ and
-- the moment it last wrote one, and @\/status.attestation@ publishes the lot. The age of that
-- report is also the only evidence of a projector that DIED while db-sync was stalled too — two
-- frozen slot numbers whose difference is zero.
--
-- The lag is measured against db-sync's tip rather than the wall clock, because both numbers then
-- come from the same source and a slow database shows up once rather than twice. Clamped at zero:
-- the projector reads from Kupo and can legitimately be AHEAD of db-sync.
startFreshnessPoll :: ConnectionPool -> Int -> IO (TVar (Maybe Freshness), TVar (Maybe AttestationStatus), ThreadId)
startFreshnessPoll pool pollMs = do
  tv <- newTVarIO Nothing
  av <- newTVarIO Nothing
  poll tv av
  tid <- forkIO . forever $ do
    threadDelay (pollMs * 1000)
    poll tv av
  pure (tv, av, tid)
  where
    poll tv av = do
      r <- try (runGovRead pool freshnessQuery)
      case r of
        Right (Just f) -> do
          atomically (writeTVar tv (Just f))
          pollAttest av (freshSlot f)
        Right Nothing ->
          hPutStrLn stderr "[freshness] palmares.sync_state is empty: db-sync has no blocks yet"
        Left (e :: SomeException) ->
          hPutStrLn stderr ("[freshness] poll failed, keeping the previous value: " <> show e)

    -- Called with DB-SYNC'S OWN CURSOR in hand, not the chain tip: the caller passes `freshSlot f`,
    -- which is `palmares.sync_state.slot_no`, the last block db-sync indexed. So this lag is
    -- relative to that, and absolute staleness is this plus governance's own lag — which is why
    -- `readyVerdict` compares the SUM to its ceiling. The parameter was named `tipSlot`, which
    -- shadowed the top-level `tipSlot` that really is the tip (`max(slot_no) FROM public.block`),
    -- and the two differ by exactly the quantity this function is measuring.
    -- `CS-07`: the ROW, not the cursor. The cursor is written once a window has been applied in
    -- full, so it cannot distinguish "never started" from "caught up"; the row carries the
    -- projector's own state and the moment it last wrote one.
    pollAttest av dbSyncSlot = do
      r <- try (runGovRead pool attestSyncStateRow)
      case r of
        Right (Just row) -> do
          atomically (writeTVar av (Just (attestStatusOf dbSyncSlot row)))
        Right Nothing -> atomically (writeTVar av Nothing)
        Left (e :: SomeException) ->
          hPutStrLn stderr ("[freshness] attestation sync-state unreadable, reporting unknown: " <> show e)

-- | The projector's stored row as the API publishes it — `CS-07`.
--
-- The lag is computed HERE and not stored, because its reference is db-sync's cursor: the projector
-- writes what it knows (its own slot and Kupo's tip) and the read side subtracts, which keeps one
-- definition of the number @\/ready@ judges. Clamped at zero, because the projector follows a
-- narrow Kupo match while db-sync indexes every block, so being AHEAD is the normal case.
attestStatusOf :: Integer -> AttestSyncState -> AttestationStatus
attestStatusOf dbSyncSlot row =
  AttestationStatus
    { attestSyncSlot = attestSyncStateCursorSlot row,
      attestSyncKupoTipSlot = attestSyncStateKupoTipSlot row,
      attestSyncLagSeconds = fromIntegral (max 0 (dbSyncSlot - attestSyncStateCursorSlot row)),
      attestSyncState = attestSyncStateState row,
      attestSyncLastSyncAt = attestSyncStateLastSyncAt row,
      -- The projector's own verdict and not the service's: a completed pass with the cursor at
      -- Kupo's tip is the only state in which an attestation page is complete.
      attestSyncIsReady = attestSyncStateState row == "following",
      attestSyncPolicyId = attestSyncStatePolicyHexText row,
      attestSyncLastError = attestSyncStateLastError row,
      attestSyncSource = "attest-sync/kupo"
    }

-- | Stamp every response with the chain point its data came from.
--
-- Five headers rather than a field in each body, because the question \"how fresh is this\"
-- applies to every response including the ones that are an error body, and because a client can
-- then show a staleness chip without parsing anything. They are added on the way out, so a
-- handler cannot forget them.
freshnessMiddleware :: IO (Maybe Freshness, Maybe AttestationStatus) -> Middleware
freshnessMiddleware readFresh app req respond = do
  (mf, ma) <- readFresh
  app req (respond . mapResponseHeaders (<> maybe [] freshnessHeaders mf <> maybe [] attestHeaders ma))

freshnessHeaders :: Freshness -> [Header]
freshnessHeaders f =
  [ ("X-Chain-Epoch", b (show (freshEpoch f))),
    ("X-Chain-Slot", b (show (freshSlot f))),
    -- iso8601Show, not `show`: Haskell renders a UTCTime as "2026-10-20 12:43:24 UTC", which no
    -- Date parser in a browser accepts. The body already carries the ISO form, so a header that
    -- did not match it would be a second, worse format for the same value.
    ("X-Chain-Block-Time", b (iso8601Show (freshBlockTime f))),
    ("X-Data-Lag-Seconds", b (show (freshLagSeconds f))),
    ("X-Data-Source", "cardano-db-sync")
  ]
  where
    b = BS8.pack

-- | The attestation projector's own three, added only when there is a projector — `CS-07`.
--
-- __Why on every response and not only on the attestation routes.__ The middleware does not know
-- which handler answered, and a client scrolling @\/attestations@ needs the state on the page it is
-- reading rather than on a second request to @\/status@. Three headers rather than five: the
-- projector publishes a cursor, so there is no epoch and no block time to stamp without inventing
-- one.
attestHeaders :: AttestationStatus -> [Header]
attestHeaders a =
  [ ("X-Attest-Slot", b (show (attestSyncSlot a))),
    ("X-Attest-Lag-Seconds", b (show (attestSyncLagSeconds a))),
    ("X-Attest-State", b (T.unpack (attestSyncState a)))
  ]
  where
    b = BS8.pack

-- | The @\/status@ sync block, from the cached freshness plus the probe's own verdict.
--
-- @is_ready@ is carried here so a client sees the same answer @\/ready@ gave without a second
-- request and without reimplementing the thresholds.
syncStatusOf :: Freshness -> Bool -> SyncStatus
syncStatusOf f isReady =
  SyncStatus
    { syncEpoch = freshEpoch f,
      syncSlot = freshSlot f,
      syncBlockTime = freshBlockTime f,
      syncLagSeconds = freshLagSeconds f,
      syncIsReady = isReady,
      syncSource = "cardano-db-sync"
    }

-- ---------------------------------------------------------------------------------------------

-- * GET /dreps

-- | The ordering each @order_by@ value means, as a TOTAL function over a closed enum.
--
-- This is the only way a column name reaches 'orderClause', and therefore the only reason
-- splicing one into SQL is safe. The tiebreaker is the same for every ordering, because what it
-- has to do is break ties, not add a second sort key a client asked for.
--
-- @NULLS LAST@ on the three rate-like columns: a DRep with no participation rate belongs after
-- one with 0%, in both directions. On @given_name@ for the same reason — an unnamed DRep is not
-- alphabetically first.
drepSortSpec :: DRepsOrderBy -> SortSpec
drepSortSpec = \case
  DRepsOrderById -> SortSpec "d.drep_hash_id" False tie
  DRepsOrderByVotingPower -> SortSpec "m.voting_power" True tie
  DRepsOrderByDelegatorCount -> SortSpec "m.delegator_count" False tie
  DRepsOrderByParticipationRate -> SortSpec "m.participation_rate" True tie
  DRepsOrderByRationaleRate -> SortSpec "m.rationale_rate" True tie
  DRepsOrderByRegisteredAt -> SortSpec "d.first_cert_slot" True tie
  DRepsOrderByVotesCast -> SortSpec "m.votes_cast" False tie
  DRepsOrderByName -> SortSpec "d.given_name" True tie
  where
    tie = "d.drep_hash_id"

-- | The FROM clause, shared by the page and the count.
--
-- Shared deliberately, and this is F-17's root-cause fix rather than a tidiness measure: a count
-- computed over a different join than the page is a total that disagrees with the rows, and the
-- disagreement only shows up as a paginator that offers a page which comes back empty.
drepFrom :: Text
drepFrom =
  " FROM palmares.drep d \
  \ JOIN palmares.drep_metrics m ON m.drep_hash_id = d.drep_hash_id \
  \ LEFT JOIN palmares.anchor a ON a.voting_anchor_id = d.voting_anchor_id "

-- | The @WHERE@ fragment and its parameters, in placeholder order.
--
-- @never_registered@ credentials are excluded by an unconditional clause, not by the status
-- filter: they exist in @drep_hash@ only because something delegated to them, @palmares.drep@'s
-- own documentation says they are not DReps, and no 'Core.DRepStatus' value names them — which is
-- exactly why the exclusion cannot be left to the status CASE.
drepWhere :: DRepFilter -> (Text, [PersistValue])
drepWhere f =
  let clauses =
        concat
          [ -- Unconditional, and it has to be explicit: the status CASE below has no arm for a
            -- credential with no certificate, so without this they fall through to 'inactive' and
            -- the default page publishes 7 non-DReps as inactive ones. Measured: the total read
            -- 301 instead of 294 until this line existed.
            [("d.registration_status <> 'never_registered'", [])],
            inClause statusExpr effectiveStatus,
            inClause "a.verdict" (drepFilterAnchorStatus f),
            one "d.has_script = ?" (drepFilterHasScript f),
            one "m.voting_power >= ?" (drepFilterMinVotingPower f),
            one "m.voting_power <= ?" (drepFilterMaxVotingPower f),
            one "m.delegator_count >= ?" (drepFilterMinDelegators f),
            one "m.participation_rate >= ?" (drepFilterMinParticipationRate f),
            one "m.rationale_rate >= ?" (drepFilterMinRationaleRate f),
            one "d.first_cert_time < ?" (drepFilterRegisteredBefore f),
            one "d.first_cert_time > ?" (drepFilterRegisteredAfter f),
            one "m.age_days >= ?" (drepFilterMinAgeDays f),
            one "d.language = ?" (drepFilterLanguage f),
            votedClause True (drepFilterVotedOn f),
            votedClause False (drepFilterNotVotedOn f),
            one
              "EXISTS (SELECT 1 FROM palmares.drep_epoch_power p \
              \ WHERE p.drep_hash_id = d.drep_hash_id AND p.epoch_no = ? AND p.amount > 0)"
              (drepFilterActiveInEpoch f),
            one "lower(d.given_name) LIKE ?" (likePat <$> drepFilterQ f)
          ]
   in ("WHERE " <> T.intercalate " AND " (map fst clauses), concatMap snd clauses)
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

    -- Placeholders are EXPANDED rather than bound as one array parameter. persistent's
    -- @PersistField [a]@ serialises a list as JSON text, which @= ANY(?)@ cannot read, and an
    -- expanded @IN (?, ?, ?)@ needs no backend-specific array encoding at all. The empty list
    -- yields NO clause, which is what makes "no status given" mean "any status".
    inClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
              map (toPersistValue . jsonTag) vs
            )
          ]

    -- The default, and the facet statement's own status predicate. See 'effectiveDRepStatus'.
    effectiveStatus = effectiveDRepStatus f

    -- status is not a column: it is `registration_status` and `is_active` composed, and the
    -- composition lives in ONE expression, 'drepStatusExpr', rather than in the projection, the
    -- filter and the facet, so none of the three can show a status another would have excluded.
    statusExpr = drepStatusExpr

    votedClause wanted = maybe [] $ \(GovActionId gid) ->
      let (txHex, ix) = T.breakOn "#" gid
          predicate =
            (if wanted then "" else "NOT ")
              <> "EXISTS (SELECT 1 FROM palmares.vote v \
                 \ JOIN palmares.gov_action g ON g.gov_action_id = v.gov_action_id \
                 \ WHERE v.drep_voter_id = d.drep_hash_id \
                 \   AND g.tx_hash = decode(?, 'hex') AND g.index = ?)"
       in [(predicate, [toPersistValue txHex, toPersistValue (T.drop 1 ix)])]

-- | One page of DReps, with a total computed over the same predicate.
listDReps ::
  DRepFilter ->
  (DRepsOrderBy, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page DRepSummary)
listDReps f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> drepProjection
          <> drepFrom
          <> whereSql
          <> " "
          <> orderClause (drepSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> drepFrom <> whereSql) params
  let total = case totals of
        (Single n : _) -> n
        [] -> 0
  pure (Page items (Just total) lim off Nothing)
  where
    (whereSql, params) = drepWhere f

-- | The projection list. Keys are 'DRepSummary''s wire names; see rule 2 in the module header.
drepProjection :: Text
drepProjection =
  " encode(d.drep_raw, 'hex') AS hex, \
  \ d.has_script, "
    <> drepStatusExpr
    <> " AS status, \
  \ d.is_active, d.active_until_epoch, d.given_name, d.image_url AS image_url, d.language, \
  \ a.verdict AS anchor_status, \
  \ (d.first_cert_time AT TIME ZONE 'UTC') AS registered_at, \
  \ floor(m.age_days)::int AS age_days, \
  \ m.voting_power, m.voting_power_epoch, m.delegator_count, \
  \ m.eligible_actions, m.votes_cast, m.participation_rate, m.rationale_rate, \
  \ m.open_actions_unvoted, \
  \ (m.last_vote_at AT TIME ZONE 'UTC') AS last_vote_at, \
  \ m.as_of_epoch "

-- ---------------------------------------------------------------------------------------------

-- * The DRep profile

-- | Resolve a credential hash to the internal id of the row that IS the DRep.
--
-- @ORDER BY (registration_status <> 'never_registered') DESC@ is the whole reason this is not a
-- plain equality: two preprod hashes exist twice in @drep_hash@, once as a key credential and
-- once as a script credential, and in both cases one of the pair has no certificate at all. The
-- registered row is the DRep; the phantom exists only because someone delegated using the
-- CIP-105 string, which cannot say which kind it meant. See 'Core.drepIdHex'.
-- | The @drep_hash@ row id of a reserved ledger option, by its @view@.
--
-- The two reserved options are @drep_hash@ rows with @raw IS NULL@, so they have a row id and a
-- power series but no credential — which is why 'resolveDRepHex' cannot find them: it matches on
-- @drep_raw@, and @palmares.drep@ deliberately holds no row for them at all (D-20 keeps them out
-- of the registry and in the distribution).
--
-- FOUND BY THE RECONCILER: @\/drep\/drep_always_abstain\/power@ answered 404 while
-- @\/pages\/dashboard@ published that same option's 431,863,790,957,959 lovelace — 46% of
-- preprod's total voting power, reachable in aggregate and not as a series. R3 and R4 compare both
-- options per epoch, so the gap was a row that could not be run.
resolveReservedDRep :: Text -> SqlPersistT IO (Maybe Int64)
resolveReservedDRep view_ = do
  rows <- rawSql "SELECT dh.id FROM public.drep_hash dh WHERE dh.view = ? LIMIT 1" [toPersistValue view_]
  pure $ case rows of
    (Single i : _) -> Just i
    [] -> Nothing

resolveDRepHex :: Text -> SqlPersistT IO (Maybe Int64)
resolveDRepHex hex = do
  rows <-
    rawSql
      "SELECT d.drep_hash_id FROM palmares.drep d \
      \ WHERE d.drep_raw = decode(?, 'hex') \
      \ ORDER BY (d.registration_status <> 'never_registered') DESC, d.drep_hash_id \
      \ LIMIT 1"
      [toPersistValue hex]
  pure $ case rows of
    (Single i : _) -> Just i
    [] -> Nothing

-- | The same summary row @\/dreps@ serves, for one DRep.
drepSummaryByIdQuery :: Int64 -> SqlPersistT IO (Maybe DRepSummary)
drepSummaryByIdQuery dhid =
  queryJson1
    ( "SELECT row_to_json(x)::text FROM ( SELECT "
        <> drepProjection
        <> drepFrom
        <> " WHERE d.drep_hash_id = ? ) x"
    )
    [toPersistValue dhid]

-- | The full metric block, including the per-type breakdown and the formula ids.
--
-- One statement, because every number in it comes from the same matview row plus one pass over
-- this DRep's eligible set: splitting it would let the headline figures and the per-type
-- breakdown be measured at different epochs.
--
-- The seven action types always appear, including at zero, through a @LEFT JOIN@ from a literal
-- type list. A missing row would read as \"no data\" where the truth is \"nothing to vote on\".
drepMetricsQuery :: Int64 -> SqlPersistT IO (Maybe DRepMetrics)
drepMetricsQuery dhid =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  WITH m AS (SELECT * FROM palmares.drep_metrics WHERE drep_hash_id = ?), \
    \  elig AS ( \
    \    SELECT e.gov_action_id, e.action_type \
    \    FROM m, palmares.eligible_actions(m.drep_hash_id, m.as_of_epoch) e \
    \  ), \
    \  final AS ( \
    \    SELECT v.gov_action_id, e.action_type, v.vote \
    \    FROM elig e \
    \    JOIN palmares.vote v ON v.gov_action_id = e.gov_action_id \
    \    WHERE v.drep_voter_id = (SELECT drep_hash_id FROM m) \
    \      AND v.voter_role = 'DRep' \
    \      AND v.voter_id_hash = (SELECT dh.raw FROM public.drep_hash dh \
    \                             WHERE dh.id = (SELECT drep_hash_id FROM m)) \
    \      AND v.seq_last = 1 \
    \  ), \
    \  types AS ( \
    \    SELECT t.action_type, \
    \           count(e.gov_action_id) AS eligible_actions, \
    \           count(DISTINCT f.gov_action_id) AS votes_cast, \
    \           count(*) FILTER (WHERE f.vote = 'Yes') AS yes, \
    \           count(*) FILTER (WHERE f.vote = 'No') AS no, \
    \           count(*) FILTER (WHERE f.vote = 'Abstain') AS abstain \
    \    FROM (VALUES ('ParameterChange'), ('HardForkInitiation'), ('TreasuryWithdrawals'), \
    \                 ('NoConfidence'), ('NewCommittee'), ('NewConstitution'), ('InfoAction')) \
    \         AS t(action_type) \
    \    LEFT JOIN elig e ON e.action_type::text = t.action_type \
    \    LEFT JOIN final f ON f.gov_action_id = e.gov_action_id \
    \    GROUP BY t.action_type \
    \  ) \
    \  SELECT m.as_of_epoch, m.eligible_actions, m.votes_cast, m.open_actions_unvoted, \
    \         m.participation_rate, \
    \         m.rationale_verified, m.rationale_inline, m.rationale_unverified, \
    \         m.rationale_pending, m.rationale_absent, m.rationale_cip100_valid, m.rationale_rate, \
    \         m.vote_latency_median_hours, m.vote_latency_p90_hours, m.vote_latency_sample, \
    \         floor(m.age_days)::int AS age_days, \
    \         json_build_object( \
    \           'yes', (SELECT count(*) FROM final WHERE vote = 'Yes'), \
    \           'no', (SELECT count(*) FROM final WHERE vote = 'No'), \
    \           'abstain', (SELECT count(*) FROM final WHERE vote = 'Abstain') \
    \         ) AS final_votes, \
    \         (SELECT json_agg(json_build_array( \
    \            lower(regexp_replace(t.action_type, '([a-z0-9])([A-Z])', '\\1_\\2', 'g')), \
    \            json_build_object( \
    \              'eligible_actions', t.eligible_actions, \
    \              'votes_cast', t.votes_cast, \
    \              'yes', t.yes, 'no', t.no, 'abstain', t.abstain, \
    \              'participation_rate', \
    \                CASE WHEN t.eligible_actions = 0 THEN NULL \
    \                     ELSE t.votes_cast::float8 / t.eligible_actions END \
    \            )) ORDER BY t.action_type) FROM types t) AS votes_by_type, \
    \         json_build_array('participation_rate_v1', 'rationale_rate_v1', 'age_days_v1', \
    \                          'delegator_retention_rate_v1', 'vote_latency_median_hours_v1', \
    \                          'votes_by_type_v1') AS formula_ids \
    \  FROM m \
    \) x"
    [toPersistValue dhid]

-- | A DRep's voting power, epoch by epoch, as the ledger recorded it.
--
-- Gaps are NOT filled. Measured on the fixture DRep: 141 points over epochs 174-320, with 203-208
-- genuinely absent from @drep_distr@. Zero-filling them would turn an absence into a measurement,
-- and a client can see the gap in the @epoch@ series.
-- | One target's voting-power series.
--
-- @targetKind@ is a PARAMETER and not the literal @'drep'@ it used to be, because the two reserved
-- ledger options carry @target_kind@ of their own in @palmares.drep_epoch_power@ (D-20) and a
-- hard-coded @'drep'@ returned an empty series for them — which reads as "this target has no
-- power" for the option holding 46% of preprod's.
-- __The delegator count comes from the FUNCTION and not from @palmares.drep_epoch_delegators@.__
-- Joining the view here made this route serve 503: the view's window function forces the whole
-- chain's delegation history before the outer predicate keeps five rows, measured at 32.9 s for one
-- credential over five epochs against a 30 s statement timeout — which also stopped the Koios parity
-- gate, because the reconciler reads this route. @palmares.drep_delegator_counts@ is the same
-- arithmetic with the one predicate that CAN be pushed through the window: 1.30 s, same counts.
--
-- The function needs an epoch range and this route's bounds are optional, so the range is taken from
-- the power series itself — which is the right range anyway, since a count for an epoch with no
-- power row has nothing to attach to. An empty series gives @NULL@ bounds, an empty series from the
-- function, and an empty page: the same answer by a shorter path.
listEpochPower :: Text -> Int64 -> Maybe Int -> Maybe Int -> SortOrder -> Limit -> SqlPersistT IO [EpochPowerPoint]
listEpochPower targetKind dhid fromEpoch toEpoch so lim =
  queryJson
    ( "SELECT row_to_json(x)::text FROM ( \
      \  WITH pw AS ( \
      \    SELECT p.epoch_no, p.amount \
      \    FROM palmares.drep_epoch_power p \
      \    WHERE p.drep_hash_id = ? AND p.target_kind = ? "
        <> maybe "" (const " AND p.epoch_no >= ? ") fromEpoch
        <> maybe "" (const " AND p.epoch_no <= ? ") toEpoch
        <> "  ) \
           \  SELECT pw.epoch_no AS epoch, pw.amount AS lovelace, dd.delegator_count \
           \  FROM pw \
           \  LEFT JOIN palmares.drep_delegator_counts( \
           \      ?, \
           \      (SELECT min(epoch_no)::int FROM pw), \
           \      (SELECT max(epoch_no)::int FROM pw) \
           \    ) dd ON dd.epoch_no = pw.epoch_no \
           \  ORDER BY pw.epoch_no "
        <> (case so of Asc -> "ASC"; Desc -> "DESC")
        <> " LIMIT ? ) x"
    )
    ( [toPersistValue dhid, toPersistValue targetKind]
        <> maybe [] (\e -> [toPersistValue e]) fromEpoch
        <> maybe [] (\e -> [toPersistValue e]) toEpoch
        <> [toPersistValue dhid, toPersistValue lim]
    )

-- | Delegator movement over the retention window, by RUNNING the published formula.
--
-- Not a second derivation of it. The first version here counted \"every address that ever
-- delegated to this DRep before epoch N\", which is a different question: measured on the fixture
-- DRep it gave 26 previous delegators and a retention rate of 0.42 where
-- @delegator_retention_rate_v1@ — which reconstructs the set from delegation intervals — gives 11
-- and 1.0. Two derivations of one published number is exactly what the catalog exists to prevent,
-- so this runs the catalog's own bytes and only wraps them in the JSON-column convention.
--
-- @window_epochs@ is interpolated rather than bound, because it is 'retentionWindowEpochs', a
-- compile-time constant, and prepending a placeholder would put it lexically before the
-- statement's own three.
delegatorStatsQuery :: Int64 -> Int -> Int -> SqlPersistT IO (Maybe DelegatorStats)
delegatorStatsQuery dhid asOfEpoch window =
  case lookupMetricSql "delegator_retention_rate_v1.sql" of
    Nothing -> error "Query.Gov: delegator_retention_rate_v1.sql is not embedded"
    Just sql ->
      queryJson1
        ( "SELECT row_to_json(x)::text FROM ( SELECT q.*, "
            <> T.pack (show window)
            <> "::int AS window_epochs FROM ( "
            <> TE.decodeUtf8 sqlNoSemicolon
            <> " ) q ) x"
        )
        [toPersistValue dhid, toPersistValue asOfEpoch, toPersistValue window]
      where
        -- The catalog statements end in a semicolon, which cannot appear inside a subquery.
        sqlNoSemicolon = BS8.pack (reverse (dropWhile (`elem` (";\n \t" :: String)) (reverse (BS8.unpack sql))))

-- | One page of a DRep's delegators.
--
-- @lovelace@ comes from the latest @epoch_stake@ snapshot, which is why it can be @null@ for a
-- delegation made this epoch: the stake is real and not yet weighed.
listDelegators ::
  Int64 ->
  Bool ->
  Maybe Int64 ->
  (Text, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page DelegatorRow)
listDelegators dhid isCurrent minLovelace (orderCol, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> delegatorProjection
          <> delegatorFrom
          <> whereSql
          <> " ORDER BY "
          <> orderCol
          <> " "
          <> (case so of Asc -> "ASC"; Desc -> "DESC")
          <> " NULLS LAST, dv.addr_id ASC LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> delegatorFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    whereSql =
      " WHERE dv.drep_hash_id = ? "
        <> (if isCurrent then " AND l.addr_id IS NOT NULL " else "")
        <> maybe "" (const " AND es.amount >= ? ") minLovelace
    params = [toPersistValue dhid] <> maybe [] (\v -> [toPersistValue v]) minLovelace

-- | The join every delegator query shares, so the page and the total cannot drift.
delegatorFrom :: Text
delegatorFrom =
  " FROM ( SELECT DISTINCT ON (addr_id) addr_id, stake_address, drep_hash_id, \
  \               slot_no, epoch_no, delegated_at, tx_hash \
  \        FROM palmares.vote_delegation \
  \        ORDER BY addr_id, slot_no DESC, tx_index DESC, cert_index DESC ) dv \
  \ LEFT JOIN palmares.live_delegation l \
  \   ON l.addr_id = dv.addr_id AND l.drep_hash_id = dv.drep_hash_id \
  \ LEFT JOIN ( SELECT addr_id, amount FROM public.epoch_stake \
  \             WHERE epoch_no = (SELECT max(epoch_no) FROM public.epoch_stake) ) es \
  \   ON es.addr_id = dv.addr_id "

delegatorProjection :: Text
delegatorProjection =
  " dv.stake_address, es.amount AS lovelace, \
  \ json_build_object('slot', dv.slot_no, 'epoch', dv.epoch_no, \
  \                   'time', (dv.delegated_at AT TIME ZONE 'UTC'), \
  \                   'tx_hash', encode(dv.tx_hash, 'hex')) AS delegated_at, \
  \ (l.addr_id IS NOT NULL) AS is_current "

-- | A DRep's certificate history.
listDRepUpdates :: Int64 -> [Text] -> SortOrder -> (Limit, Offset) -> SqlPersistT IO (Page DRepUpdateRow)
listDRepUpdates dhid kinds so (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( \
        \  SELECT CASE c.cert_kind WHEN 'register' THEN 'registered' \
        \                          WHEN 'retire' THEN 'retired' ELSE 'updated' END AS kind, \
        \         json_build_object('slot', c.slot_no, 'epoch', c.epoch_no, \
        \                           'time', (c.cert_time AT TIME ZONE 'UTC'), \
        \                           'tx_hash', encode(c.tx_hash, 'hex')) AS at, \
        \         c.deposit, va.url AS anchor_url, a.verdict AS anchor_status \
        \  FROM palmares.drep_cert c \
        \  LEFT JOIN public.voting_anchor va ON va.id = c.voting_anchor_id \
        \  LEFT JOIN palmares.anchor a ON a.voting_anchor_id = c.voting_anchor_id "
          <> whereSql
          <> " ORDER BY c.slot_no "
          <> (case so of Asc -> "ASC"; Desc -> "DESC")
          <> ", c.cert_index "
          <> (case so of Asc -> "ASC"; Desc -> "DESC")
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int FROM palmares.drep_cert c" <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    kindExpr =
      "(CASE c.cert_kind WHEN 'register' THEN 'registered' \
      \                  WHEN 'retire' THEN 'retired' ELSE 'updated' END)"
    whereSql =
      " WHERE c.drep_hash_id = ? "
        <> ( if null kinds
               then ""
               else " AND " <> kindExpr <> " IN (" <> T.intercalate ", " (map (const "?") kinds) <> ") "
           )
    params = [toPersistValue dhid] <> map toPersistValue kinds

-- | A DRep's CIP-119 metadata, but only when its anchor verdict is @valid@.
--
-- The gate is the point: a document whose hash did not match the on-chain commitment is not this
-- DRep's statement about itself, whatever it says, and publishing it under their name would be
-- the registry asserting something it cannot verify.
anchorContentQuery :: Int64 -> SqlPersistT IO (Maybe AnchorContent)
anchorContentQuery dhid =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT dd.given_name, dd.objectives, dd.motivations, dd.qualifications, \
    \         dd.image_url, dd.payment_address, \
    \         COALESCE(( SELECT json_agg(json_build_object('label', r.label, 'uri', r.uri) \
    \                                    ORDER BY r.id) \
    \                    FROM public.off_chain_vote_reference r \
    \                    WHERE r.off_chain_vote_data_id = dd.off_chain_vote_data_id ), '[]'::json) \
    \           AS references \
    \  FROM palmares.drep d \
    \  JOIN palmares.anchor a ON a.voting_anchor_id = d.voting_anchor_id \
    \  JOIN ( SELECT DISTINCT ON (off_chain_vote_data_id) * \
    \         FROM public.off_chain_vote_drep_data ORDER BY off_chain_vote_data_id, id ) dd \
    \    ON dd.off_chain_vote_data_id = a.off_chain_vote_data_id \
    \  WHERE d.drep_hash_id = ? AND a.verdict = 'valid' \
    \  LIMIT 1 \
    \) x"
    [toPersistValue dhid]

-- | The column each delegator ordering means. A closed total function, for the reason
-- 'drepSortSpec' gives.
delegatorOrderColumn :: DelegatorsOrderBy -> Text
delegatorOrderColumn = \case
  DelegatorsOrderByLovelace -> "es.amount"
  DelegatorsOrderByDelegatedAt -> "dv.slot_no"
  DelegatorsOrderByStakeAddress -> "dv.stake_address"

-- ---------------------------------------------------------------------------------------------

-- * GET /gov-actions

-- | The ordering each @order_by@ value means. Closed and total, as 'drepSortSpec' is.
--
-- @NULLS LAST@ on the two columns that are legitimately absent: a non-treasury action has no
-- treasury amount, and an action with no expiration recorded has no expiry epoch.
govActionSortSpec :: GovActionsOrderBy -> SortSpec
govActionSortSpec = \case
  GovActionsOrderByProposedAt -> SortSpec "g.proposed_slot" False tie
  GovActionsOrderByExpiresEpoch -> SortSpec "g.expiration" True tie
  GovActionsOrderByType -> SortSpec "g.action_type" False tie
  GovActionsOrderByDeposit -> SortSpec "g.deposit" True tie
  GovActionsOrderByTreasuryAmount -> SortSpec "g.withdrawal_total" True tie
  GovActionsOrderByVotesCast -> SortSpec "g.votes_cast" False tie
  where
    tie = "g.gov_action_id"

-- | The FROM clause the page and the count share, for F-17's reason.
-- No join to stake_address: palmares.gov_action already publishes `return_address` as the bech32
-- string, not as the row id. Joining on it compared a bigint to a varchar, which PostgreSQL
-- rejects outright rather than coercing — the right behaviour, and the reason this was a boot-time
-- 503 rather than a wrong answer.
govActionFrom :: Text
govActionFrom =
  " FROM palmares.gov_action g \
  \ LEFT JOIN palmares.anchor a ON a.voting_anchor_id = g.voting_anchor_id "

-- | The @WHERE@ fragment and its parameters.
govActionWhere :: GovActionFilter -> (Text, [PersistValue])
govActionWhere f =
  let clauses =
        concat
          [ inClause "g.action_type::text" (map pascalTag (govActionFilterTypes f)),
            inClause "g.state" (map jsonTag (govActionFilterStates f)),
            inClause "a.verdict" (map jsonTag (govActionFilterAnchorStatus f)),
            one "g.proposed_at >= ?" (govActionFilterProposedFrom f),
            one "g.proposed_at <= ?" (govActionFilterProposedTo f),
            one "g.expiration < ?" (govActionFilterExpiresBeforeEpoch f),
            one "g.expiration > ?" (govActionFilterExpiresAfterEpoch f),
            one "g.return_address = ?" (govActionFilterProposerStakeAddress f),
            one "g.withdrawal_total >= ?" (govActionFilterMinTreasuryAmount f),
            one "g.withdrawal_total <= ?" (govActionFilterMaxTreasuryAmount f),
            one
              "(lower(g.title) LIKE ? OR lower(g.abstract) LIKE ?)"
              (likePat <$> govActionFilterQ f)
          ]
   in ( if null clauses then "" else "WHERE " <> T.intercalate " AND " (map fst clauses),
        concatMap snd clauses
      )
  where
    -- `q` binds the same pattern to two placeholders, so it is duplicated here rather than in the
    -- clause: one `?` per bind is the invariant the placeholder-count test checks.
    one sql v
      | sql == "(lower(g.title) LIKE ? OR lower(g.abstract) LIKE ?)" =
          maybe [] (\p -> [(sql, [toPersistValue p, toPersistValue p])]) v
      | otherwise = maybe [] (\x -> [(sql, [toPersistValue x])]) v

    inClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
              map toPersistValue vs
            )
          ]

    -- action_type is db-sync's govactiontype enum, whose labels are PascalCase; the wire form is
    -- snake_case. Mapping back through the enum's own Show is safe because the constructor names
    -- and the db labels are the same strings — which is why GovActionType was spelled db-sync's
    -- way rather than the ledger's (UpdateCommittee vs NewCommittee).
    pascalTag = T.pack . show

-- | One page of governance actions, with a total over the same predicate.
listGovActions ::
  GovActionFilter ->
  (GovActionsOrderBy, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page GovActionSummary)
listGovActions f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> govActionProjection
          <> govActionFrom
          <> whereSql
          <> " "
          <> orderClause (govActionSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> govActionFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    (whereSql, params) = govActionWhere f

-- | The projection list. Keys are 'GovActionSummary''s wire names.
govActionProjection :: Text
govActionProjection =
  " encode(g.tx_hash, 'hex') AS tx_hash, g.index, \
  \ lower(regexp_replace(g.action_type::text, '([a-z0-9])([A-Z])', '\\1_\\2', 'g')) AS type, \
  \ g.title, g.abstract, a.verdict AS anchor_status, \
  \ json_build_object('slot', g.proposed_slot, 'epoch', g.proposed_epoch, \
  \                   'time', (g.proposed_at AT TIME ZONE 'UTC'), \
  \                   'tx_hash', encode(g.tx_hash, 'hex')) AS proposed_at, \
  \ g.expiration AS expires_epoch, g.last_votable_epoch, \
  \ json_build_object('state', g.state, \
  \                   'ratified_epoch', g.ratified_epoch, \
  \                   'enacted_epoch', g.enacted_epoch, \
  \                   'expired_epoch', g.expired_epoch, \
  \                   'dropped_epoch', g.dropped_epoch, \
  \                   'formula_id', 'gov_action_state_v1') AS lifecycle, \
  \ g.deposit, g.return_address, g.withdrawal_total AS treasury_amount, \
  \ g.votes_cast "

-- ---------------------------------------------------------------------------------------------

-- * The governance action page

-- | Resolve a canonical @\<tx_hash\>#\<index\>@ to the internal proposal id.
resolveGovAction :: Text -> Int -> SqlPersistT IO (Maybe Int64)
resolveGovAction txHex ix = do
  rows <-
    rawSql
      "SELECT g.gov_action_id FROM palmares.gov_action g \
      \ WHERE g.tx_hash = decode(?, 'hex') AND g.index = ? LIMIT 1"
      [toPersistValue txHex, toPersistValue ix]
  pure $ case rows of
    (Single i : _) -> Just i
    [] -> Nothing

-- | One action's summary row.
govActionByIdQuery :: Int64 -> SqlPersistT IO (Maybe GovActionSummary)
govActionByIdQuery gaid =
  queryJson1
    ( "SELECT row_to_json(x)::text FROM ( SELECT "
        <> govActionProjection
        <> govActionFrom
        <> " WHERE g.gov_action_id = ? ) x"
    )
    [toPersistValue gaid]

-- | The tallies, one per role that actually voted.
--
-- Not a fixed three: a role with no votes has no tally, and a zero row would read as \"they voted
-- and it came to zero\". @threshold@ and @threshold_param@ come from @palmares.vote_tally@, which
-- resolves them through the static map — except for ParameterChange\/DRep, which the view
-- deliberately leaves NULL because it is a maximum over parameter groups.
-- 'fillParamChangeThreshold' is what completes that one case.
listTallies :: Int64 -> SqlPersistT IO [VoteTally]
listTallies gaid =
  queryJson
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT lower(regexp_replace(t.voter_role::text, '([a-z0-9])([A-Z])', '\\1_\\2', 'g')) AS role_raw, \
    \         CASE t.voter_role WHEN 'DRep' THEN 'drep' WHEN 'SPO' THEN 'spo' \
    \                           ELSE 'constitutional_committee' END AS role, \
    \         t.epoch, \
    \         COALESCE(t.yes_power, 0) AS yes_power, \
    \         COALESCE(t.no_power, 0) AS no_power, \
    \         COALESCE(t.abstain_power, 0) AS abstain_power, \
    \         t.yes_count, t.no_count, t.abstain_count, \
    \         t.ratio, t.threshold, t.threshold_param, \
    \         t.basis, 'tally_cast_votes_v1' AS formula_id \
    \  FROM palmares.vote_tally t \
    \  WHERE t.gov_action_id = ? \
    \  ORDER BY t.voter_role \
    \) x"
    [toPersistValue gaid]

-- | The payments a treasury withdrawal would make.
listWithdrawals :: Int64 -> SqlPersistT IO [TreasuryWithdrawalRow]
listWithdrawals gaid =
  queryJson
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT w.stake_address AS beneficiary, w.amount, w.paid_heuristic, \
    \         CASE WHEN w.enacted_epoch IS NULL THEN NULL \
    \              ELSE json_build_object( \
    \                     'slot', NULL, 'epoch', w.enacted_epoch, 'tx_hash', NULL, \
    \                     'time', (SELECT (min(b.time) AT TIME ZONE 'UTC') FROM public.block b \
    \                               WHERE b.epoch_no = w.enacted_epoch)) END AS enacted_at \
    \  FROM palmares.treasury_withdrawal w \
    \  WHERE w.gov_action_id = ? \
    \  ORDER BY w.amount DESC, w.stake_address \
    \) x"
    [toPersistValue gaid]

-- | The protocol parameters a ParameterChange action would change.
--
-- Read out of @param_proposal@ as a row of JSON, so the set of columns is the table's rather than
-- a list this code keeps in step with it. The bookkeeping columns are excluded by name; the group
-- comes from 'Query.Thresholds.paramGroupColumns', and a @null@ group means a column that table
-- does not classify — which 'UnitTests.GovThresholds' makes impossible for the current schema.
paramChangeColumns :: Int64 -> SqlPersistT IO [Text]
paramChangeColumns gaid = do
  rows <-
    rawSql
      "SELECT t.k FROM public.gov_action_proposal g \
      \ JOIN public.param_proposal pp ON pp.id = g.param_proposal \
      \ CROSS JOIN LATERAL jsonb_each_text(to_jsonb(pp)) AS t(k, v) \
      \ WHERE g.id = ? AND t.v IS NOT NULL \
      \   AND t.k NOT IN ('id', 'epoch_no', 'key', 'registered_tx_id') \
      \ ORDER BY t.k"
      [toPersistValue gaid]
  pure [k | Single k <- rows]

-- | Who proposed the action, and how many actions they have proposed in total.
proposerQuery :: Int64 -> SqlPersistT IO (Maybe ProposerSummary)
proposerQuery gaid =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT g.return_address AS stake_address, \
    \         (SELECT count(*)::int FROM palmares.gov_action g2 \
    \           WHERE g2.return_address = g.return_address) AS actions_count \
    \  FROM palmares.gov_action g \
    \  WHERE g.gov_action_id = ? AND g.return_address IS NOT NULL \
    \) x"
    [toPersistValue gaid]

-- | A governance action's CIP-108 metadata, gated on a @valid@ anchor verdict.
--
-- The DISTINCT ON is the db-sync 13.7.x duplicate-child-row bug again: measured, 131 actions read
-- as 135 through this table, which double-counted six treasury totals before it was pinned.
govActionAnchorQuery :: Int64 -> SqlPersistT IO (Maybe GovActionAnchorContent)
govActionAnchorQuery gaid =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT gd.title, gd.abstract, gd.motivation, gd.rationale, \
    \         COALESCE(( SELECT json_agg(json_build_object('label', r.label, 'uri', r.uri) \
    \                                    ORDER BY r.id) \
    \                    FROM public.off_chain_vote_reference r \
    \                    WHERE r.off_chain_vote_data_id = gd.off_chain_vote_data_id ), '[]'::json) \
    \           AS references \
    \  FROM palmares.gov_action g \
    \  JOIN palmares.anchor a ON a.voting_anchor_id = g.voting_anchor_id \
    \  JOIN ( SELECT DISTINCT ON (off_chain_vote_data_id) * \
    \         FROM public.off_chain_vote_gov_action_data ORDER BY off_chain_vote_data_id, id ) gd \
    \    ON gd.off_chain_vote_data_id = a.off_chain_vote_data_id \
    \  WHERE g.gov_action_id = ? AND a.verdict = 'valid' \
    \  LIMIT 1 \
    \) x"
    [toPersistValue gaid]

-- | Evaluate a threshold EXPRESSION over @palmares.thresholds@ at one epoch.
--
-- The expression comes from 'Query.Thresholds.drepParamChangeThreshold', which builds it from a
-- closed column table — the same property that makes 'orderClause' safe to splice. No request
-- text reaches this statement.
thresholdValueAt :: Text -> Int -> SqlPersistT IO (Maybe Double)
thresholdValueAt expr epoch = do
  rows <-
    rawSql
      ("SELECT (" <> expr <> ")::float8 FROM palmares.thresholds WHERE epoch_no = ? LIMIT 1")
      [toPersistValue epoch]
  pure $ case rows of
    (Single v : _) -> v
    [] -> Nothing

-- ---------------------------------------------------------------------------------------------

-- * GET /votes

-- | The ordering each @order_by@ value means. Closed and total.
voteSortSpec :: VotesOrderBy -> SortSpec
voteSortSpec = \case
  VotesOrderByCastAt -> SortSpec "v.vote_slot" False tie
  VotesOrderByVotingPower -> SortSpec "p.amount" True tie
  VotesOrderByLatency -> SortSpec "(v.cast_at - w.proposed_at)" True tie
  VotesOrderByVoterId -> SortSpec "v.voter_id_hash" False tie
  VotesOrderByGovActionId -> SortSpec "v.gov_action_id" False tie
  where
    tie = "v.voting_procedure_id"

-- | The FROM clause the page and the count share.
--
-- The power join reads @palmares.drep_epoch_power@ at the action's LAST VOTABLE EPOCH, not at the
-- vote's own epoch: that is the epoch the ledger weighs the vote in, and a DRep's stake moves
-- between the two.
voteFrom :: Text
voteFrom =
  " FROM palmares.vote v \
  \ JOIN palmares.gov_action w ON w.gov_action_id = v.gov_action_id \
  \ LEFT JOIN palmares.anchor a ON a.voting_anchor_id = v.voting_anchor_id \
  \ LEFT JOIN palmares.drep_epoch_power p \
  \   ON p.target_kind = 'drep' AND p.drep_raw = v.voter_id_hash \
  \  AND p.epoch_no = w.last_votable_epoch \
  \ LEFT JOIN palmares.drep d ON d.drep_raw = v.voter_id_hash "

-- | The @WHERE@ fragment and its parameters.
voteWhere :: VoteFilter -> (Text, [PersistValue])
voteWhere f =
  let clauses =
        concat
          [ inClause "v.voter_role::text" (map pascalRole (voteFilterRoles f)),
            -- The voter is matched on the HASH, decoded from whichever id form the client sent,
            -- which is what lets one parameter serve all three roles: a committee cold key, a
            -- DRep credential and a pool hash are all 28 bytes and palmares.vote's voter_id_hash
            -- is already the cold one for committee rows.
            --
            -- Compared as BYTES, with decode() on the parameter side, not as hex with encode() on
            -- the column. That is a performance decision: voter_id_hash is in the PARTITION BY of
            -- palmares.vote's window functions, so a qual directly on it is pushed below the
            -- WindowAgg and the query touches only that voter's rows. Wrapped in encode() the
            -- planner cannot see it as a partition-column qual, and every voter_id lookup pays a
            -- full pass over 3.24 M rows instead.
            byteaInClause "v.voter_id_hash" (voteFilterVoterIds f),
            inClause "encode(w.tx_hash, 'hex') || '#' || w.index" (map unGovActionId (voteFilterGovActionIds f)),
            inClause "v.vote::text" (map pascalVerdict (voteFilterVerdicts f)),
            inClause "w.action_type::text" (map (T.pack . show) (voteFilterGovActionTypes f)),
            inClause "a.verdict" (map jsonTag (voteFilterAnchorStatus f)),
            one "v.cast_at >= ?" (voteFilterFrom f),
            one "v.cast_at <= ?" (voteFilterTo f),
            one "v.vote_epoch >= ?" (voteFilterFromEpoch f),
            one "v.vote_epoch <= ?" (voteFilterToEpoch f),
            qClause (voteFilterQ f)
          ]
   in ( if null clauses then "" else "WHERE " <> T.intercalate " AND " (map fst clauses),
        concatMap snd clauses
      )
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

    inClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
              map toPersistValue vs
            )
          ]

    byteaInClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "decode(?, 'hex')") vs) <> ")",
              map toPersistValue vs
            )
          ]

    -- Three placeholders, one pattern: the action's title, its abstract, and the voter's name.
    qClause = maybe [] $ \raw ->
      let p = likePat raw
       in [ ( "(lower(w.title) LIKE ? OR lower(w.abstract) LIKE ? OR lower(d.given_name) LIKE ?)",
              [toPersistValue p, toPersistValue p, toPersistValue p]
            )
          ]

    -- db-sync's enums are PascalCase; VoterRole's wire form is not derivable from its constructor
    -- (drep, spo), so the two spellings are mapped explicitly here and nowhere else.
    pascalRole r = case r of
      DRep -> "DRep" :: Text
      SPO -> "SPO"
      ConstitutionalCommittee -> "ConstitutionalCommittee"

    pascalVerdict v = case v of
      Yes -> "Yes" :: Text
      No -> "No"
      Abstain -> "Abstain"

-- | One page of votes, with a total over the same predicate — in FOUR statements.
--
-- __Why four.__ Reading the page straight off @palmares.vote@ could not answer at all for the
-- committee role, which is 3,243,802 of preprod's 3,244,711 vote rows. MEASURED: the page
-- statement 27.5 s and the count 24.0 s through psql, over 400 s through the service, and the 30 s
-- read ceiling turned it into a definite 503 rather than a hang. Every other role answered in
-- seconds, because @voter_role@ is a partition column of that view's window functions and the qual
-- pushes below the @WindowAgg@ — spo is 90 rows, drep 819.
--
-- The cost was measured to its cause and it was NOT the window functions. Over the committee rows:
-- the base scan is 1.09 s, @tx ⋈ block@ adds 8.7 s, @cc_cold_interval@ adds 9.5 s, and the windows
-- another 3.5 s. A count needs none of the three; a page of fifty rows needs the windows for fifty
-- rows. So:
--
--   1. __the count__, over @voting_procedure ⋈ gov_action@ plus only the joins the FILTERS need:
--      1.09 s where it was 14.2 s;
--   2. __the page's row ids__, the same shape with @ORDER BY@ and @LIMIT@: 6 ms, because the
--      default sort is @v.id DESC@ and needs no join at all ('voteBaseSortSpec' has the proof);
--   3. __those ids to their partition keys__, restricted BY the ids: 291 ms, where the same
--      cold-key join over the whole corpus is 9.5 s;
--   4. __the page's rows__, through @palmares.vote@ restricted to those partitions: 286 ms.
--
-- About 1.7 s in total, from over 400. Stage 3 is a stage of its own because folding it into
-- stage 2 was measured and cost 3.8 s of a 3.8 s page: resolving the cold credential alongside the
-- @ORDER BY@ puts that join back over everything the filter matched.
--
-- __Stage 4 binds the partition keys as PARAMETERS, and that is load-bearing.__ The same
-- restriction written as @(voter_id_hash, gov_action_id) IN (SELECT …)@ is 3,340 ms, because a
-- SubLink is opaque to @qual_is_pushdown_safe@ and the windows are then computed over the whole
-- corpus before the filter applies. As bound values it is 286 ms. The id list is bound too: the
-- pairs give the pushdown, the ids give exactness — two rows of one partition can both match the
-- pairs while only one of them is on this page.
listVotes :: VoteFilter -> (VotesOrderBy, SortOrder) -> (Limit, Offset) -> SqlPersistT IO (Page VoteRecord)
listVotes f (ob, so) (lim, off) = do
  totals <- rawSql ("SELECT count(*)::int" <> baseFrom <> baseWhereSql) baseParams
  let total = case totals of (Single n : _) -> n; [] -> 0

  idRows <-
    rawSql
      ( "SELECT v.id"
          <> baseFrom
          <> baseWhereSql
          <> " "
          <> orderClause (voteBaseSortSpec ob) so
          <> " LIMIT ? OFFSET ?"
      )
      (baseParams <> [toPersistValue lim, toPersistValue off])
  let ids = [i | Single i <- idRows] :: [Int64]

  keys <-
    if null ids
      then pure []
      else
        rawSql
          ( "SELECT v.id, encode(COALESCE(ccold.cold_raw, kdh.raw, kph.hash_raw, kch.raw), 'hex'), \
            \       v.gov_action_proposal_id \
            \ FROM public.voting_procedure v "
              <> keyJoins
              <> " WHERE v.id IN ("
              <> T.intercalate ", " ["?" | _ <- ids]
              <> ")"
          )
          (map toPersistValue ids)
  let triples = [(i, h, g) | (Single i, Single h, Single g) <- keys] :: [(Int64, Text, Int64)]

  items <-
    if null triples
      then pure []
      else
        queryJson
          ( "SELECT row_to_json(x)::text FROM ( SELECT "
              <> voteProjection
              <> voteFrom
              <> " WHERE (v.voter_id_hash, v.gov_action_id) IN ("
              <> T.intercalate ", " ["(decode(?, 'hex'), ?)" | _ <- triples]
              <> ") AND v.voting_procedure_id IN ("
              <> T.intercalate ", " ["?" | _ <- triples]
              <> ") "
              <> orderClause (voteSortSpec ob) so
              <> " ) x"
          )
          ( concat [[toPersistValue h, toPersistValue g] | (_, h, g) <- triples]
              <> [toPersistValue i | (i, _, _) <- triples]
          )
  pure (Page items (Just total) lim off Nothing)
  where
    joins = voteJoinsFor f ob
    baseFrom = voteBaseFrom joins <> (if vjCold joins then voteIdentityJoins else "")
    (baseWhereSql, baseParams) = voteBaseWhere f
    -- Stage 3's joins: the published identity for fifty primary keys. The cold interval is here
    -- and NOT in the base shape, which is the whole point of splitting stage 3 off.
    keyJoins =
      " LEFT JOIN palmares.cc_cold_interval ccold \
      \   ON ccold.hot_key_id = v.committee_voter AND ccold.from_tx <= v.tx_id \
      \  AND (ccold.to_tx IS NULL OR ccold.to_tx > v.tx_id) \
      \ LEFT JOIN public.drep_hash kdh ON kdh.id = v.drep_voter \
      \ LEFT JOIN public.pool_hash kph ON kph.id = v.pool_voter \
      \ LEFT JOIN public.committee_hash kch ON kch.id = v.committee_voter "

-- | The projection list. Keys are 'VoteRecord''s wire names.
voteProjection :: Text
voteProjection =
  " encode(w.tx_hash, 'hex') AS tx_hash, w.index, \
  \ lower(regexp_replace(w.action_type::text, '([a-z0-9])([A-Z])', '\\1_\\2', 'g')) AS gov_action_type, \
  \ w.title AS gov_action_title, \
  \ CASE v.voter_role WHEN 'DRep' THEN 'drep' WHEN 'SPO' THEN 'spo' \
  \                   ELSE 'constitutional_committee' END AS voter_role, \
  \ encode(v.voter_id_hash, 'hex') AS voter_id_hash, \
  \ CASE v.voter_role \
  \   WHEN 'DRep' THEN COALESCE(v.has_script, FALSE) \
  \   WHEN 'SPO' THEN FALSE \
  \   ELSE COALESCE(v.voter_cold_has_script, FALSE) \
  \ END AS has_script, \
  \ encode(v.voter_hot_hash, 'hex') AS voter_hot_hash, \
  \ d.given_name AS voter_name, \
  \ lower(v.vote::text) AS verdict, \
  \ json_build_object('slot', v.vote_slot, 'epoch', v.vote_epoch, \
  \                   'time', (v.cast_at AT TIME ZONE 'UTC'), \
  \                   'tx_hash', encode(v.vote_tx_hash, 'hex')) AS cast_at, \
  \ EXTRACT(EPOCH FROM (v.cast_at - w.proposed_at)) / 3600.0 AS latency_hours, \
  \ (v.seq_last = 1) AS is_final, (v.seq_first = 1) AS is_first, v.vote_rows AS revote_count, \
  \ CASE WHEN v.voting_anchor_id IS NULL THEN NULL \
  \      ELSE json_build_object('url', a.url, 'status', a.verdict, 'cip100_valid', a.cip100_valid) \
  \      END AS anchor, \
  \ p.amount AS voting_power, \
  \ CASE WHEN p.amount IS NULL THEN NULL ELSE w.last_votable_epoch END AS voting_power_epoch "

-- ---------------------------------------------------------------------------------------------

-- * GET /search

-- | The @(tx_hash_hex, index)@ a pasted governance-action id names, or @("", -1)@ for anything
-- that is not one.
--
-- Both published forms are accepted — the canonical @\<tx_hash\>#\<index\>@ and the CIP-129
-- @gov_action1…@ — which is the same pair @FromHttpApiData GovActionId@ accepts. A bare 64-hex
-- transaction hash deliberately is NOT one of them: a transaction can carry several proposals, so
-- the hash alone does not name an action.
--
-- The miss is a BOUND VALUE and not a branch in the SQL. That keeps one statement with one
-- placeholder list for every query, and @-1@ cannot collide: a @GovActionIx@ is unsigned.
searchActionId :: Text -> (Text, Int64)
searchActionId t = case T.splitOn "#" t of
  [h, i] | T.length h == 64, T.all isHexDigit h, Just n <- readMaybe (T.unpack i) -> (T.toLower h, n)
  _ -> case parseGovActionIdCip129 t of
    Right (h, ix) -> (h, fromIntegral ix)
    Left _ -> ("", -1)

-- | The whole command palette in ONE statement: one round trip, one @RepeatableRead@ snapshot, one
-- @row_to_json@ column, decoded by 'SearchResults'' own 'FromJSON'.
--
-- __Four CTEs, one per group, and nothing conditional in the text.__ Each is gated by a bound
-- BOOLEAN rather than by assembling the statement from the requested @kinds@: a statement whose
-- shape depends on the request is a statement whose placeholder list can drift from its binds, and
-- @WHERE false@ collapses to a one-time filter anyway. MEASURED warm: all four groups 28.7 ms,
-- @kinds=drep@ alone 25.9 ms, @kinds=spo@ alone 7.1 ms — the gate really does skip the arm.
--
-- Each CTE is referenced TWICE, by its count and by its page, so PostgreSQL materialises it and the
-- group's total and its items come from one evaluation of one predicate. That is F-17's rule again:
-- a count over a different pass than the rows is a total that disagrees with them.
--
-- __An id paste is matched by EQUALITY after a checksum-verified decode, never by a prefix.__
-- 'anyVoterIdHex' resolves @drep1y…@, @drep1…@, @cc_cold1…@, @cc_hot1…@, @pool1…@ and 56 hex
-- characters to one 28-byte hash, which is why one bind serves the DRep, pool and committee arms.
-- A partial bech32 string is not an id and is not matched as one: MEASURED, @pool1@ as a prefix
-- matches all 686 preprod pools and @drep1@ would match every DRep, so a five-character paste would
-- fill the palette with the whole table. A miss binds the empty string, and @decode('', 'hex')@ is
-- the empty bytea, which no credential column can equal.
--
-- __The committee group is id-only, and that is the data rather than a shortcut:__ @committee_hash@
-- has no metadata table anywhere in db-sync, so a committee member has no name to search.
-- @spos@ matches a ticker or a metadata name, which on this database finds nothing — MEASURED,
-- @public.off_chain_pool_data@ holds 0 rows for 686 pools and @off_chain_pool_fetch_error@ holds 0
-- too, so db-sync's off-chain pool fetcher has never run here. The clauses stay because they name
-- the right columns and the group fills itself the day it does.
searchQuery :: Text -> [SearchKind] -> Int -> SqlPersistT IO SearchResults
searchQuery q kinds lim = do
  r <- queryJson1 searchSql binds
  -- The outer SELECT has no FROM clause, so it returns exactly one row by construction.
  maybe (error "Query.Gov.searchQuery: the palette statement returned no row") pure r
  where
    -- An empty `kinds` is every group, which is what makes the parameter optional.
    want k = null kinds || k `elem` kinds
    pat = likePat q
    credHex = fromMaybe "" (anyVoterIdHex q)
    (actionTx, actionIx) = searchActionId q
    lim' = toPersistValue (fromIntegral lim :: Int64)
    binds =
      [ toPersistValue (want SearchDrep),
        toPersistValue pat,
        toPersistValue credHex,
        toPersistValue (want SearchGovAction),
        toPersistValue pat,
        toPersistValue pat,
        toPersistValue actionTx,
        toPersistValue actionIx,
        toPersistValue (want SearchSpo),
        toPersistValue pat,
        toPersistValue pat,
        toPersistValue credHex,
        toPersistValue (want SearchCommitteeMember),
        toPersistValue credHex,
        toPersistValue q,
        lim',
        lim',
        lim',
        lim'
      ]

-- | The palette statement. Keys are 'SearchHit''s and 'SearchResults'' wire names.
--
-- @DISTINCT ON@ on two of the four arms, both measured rather than defensive:
--
--   * @palmares.committee_member@ publishes one row per (cold credential, committee), and preprod
--     has 110 rows for 48 cold credentials — so a @cc_cold1…@ paste would return the same member up
--     to three times. Ordered @is_enacted DESC@ so the surviving row is the member's standing on the
--     committee in force.
--   * @off_chain_pool_data@ is unique on @(pool_id, pmr_id)@, not on @pool_id@, and preprod has
--     1,208 @pool_metadata_ref@ rows for 686 pools — so the LEFT JOIN fans a pool out once the
--     fetcher runs. Newest metadata wins, which is the shape @palmares.drep@'s own @drep_meta@ and
--     @palmares.gov_action@'s @action_meta@ already use for the same db-sync defect.
searchSql :: Text
searchSql =
  "SELECT row_to_json(x)::text FROM ( \
  \WITH d AS ( \
  \  SELECT d.drep_hash_id AS ord, 'drep'::text AS kind, \
  \         encode(d.drep_raw, 'hex') AS hex, d.has_script, \
  \         d.given_name AS title, encode(d.drep_raw, 'hex') AS subtitle, \
  \         CASE WHEN d.has_script THEN json_build_array('script') \
  \              ELSE json_build_array() END AS badges, "
    <> drepStatusExpr
    <> " AS status \
  \  FROM palmares.drep d \
  \  WHERE ? AND d.registration_status <> 'never_registered' \
  \    AND (lower(d.given_name) LIKE ? OR d.drep_raw = decode(?, 'hex')) \
  \), \
  \g AS ( \
  \  SELECT g.proposed_slot AS ord, 'gov_action'::text AS kind, \
  \         encode(g.tx_hash, 'hex') AS tx_hash, g.index, \
  \         g.title, COALESCE(left(g.abstract, 140), '') AS subtitle, \
  \         json_build_array(lower(regexp_replace(g.action_type::text, \
  \                                               '([a-z0-9])([A-Z])', '\\1_\\2', 'g'))) AS badges, \
  \         g.state AS status \
  \  FROM palmares.gov_action g \
  \  WHERE ? AND (lower(g.title) LIKE ? OR lower(g.abstract) LIKE ? \
  \               OR (g.tx_hash = decode(?, 'hex') AND g.index = ?)) \
  \), \
  \p AS ( \
  \  SELECT DISTINCT ON (ph.id) \
  \         ph.id AS ord, 'spo'::text AS kind, \
  \         encode(ph.hash_raw, 'hex') AS hex, false AS has_script, \
  \         COALESCE(o.ticker_name, o.json ->> 'name') AS title, \
  \         encode(ph.hash_raw, 'hex') AS subtitle, \
  \         CASE WHEN o.ticker_name IS NULL THEN json_build_array() \
  \              ELSE json_build_array(o.ticker_name) END AS badges, \
  \         NULL::text AS status \
  \  FROM public.pool_hash ph \
  \  LEFT JOIN public.off_chain_pool_data o ON o.pool_id = ph.id \
  \  WHERE ? AND (lower(o.ticker_name) LIKE ? OR lower(o.json ->> 'name') LIKE ? \
  \               OR ph.hash_raw = decode(?, 'hex')) \
  \  ORDER BY ph.id, o.pmr_id DESC \
  \), \
  \c AS ( \
  \  SELECT DISTINCT ON (m.committee_hash_id) \
  \         m.committee_hash_id AS ord, 'committee_member'::text AS kind, \
  \         encode(m.cold_hash, 'hex') AS hex, m.cold_has_script AS has_script, \
  \         NULL::text AS title, encode(m.cold_hash, 'hex') AS subtitle, \
  \         to_json(array_remove(ARRAY[CASE WHEN m.cold_has_script THEN 'script' END, \
  \                                    CASE WHEN m.is_enacted THEN 'enacted' END]::text[], NULL)) AS badges, \
  \         m.status \
  \  FROM palmares.committee_member m \
  \  WHERE ? AND m.cold_hash = decode(?, 'hex') \
  \  ORDER BY m.committee_hash_id, m.is_enacted DESC, m.committee_id DESC \
  \) \
  \SELECT ?::text AS query, \
  \       ((SELECT count(*) FROM d) + (SELECT count(*) FROM g) \
  \        + (SELECT count(*) FROM p) + (SELECT count(*) FROM c))::int AS total, \
  \       json_build_object('total', (SELECT count(*)::int FROM d), 'items', \
  \         COALESCE((SELECT json_agg(to_json(z)) FROM ( \
  \           SELECT kind, hex, has_script, title, subtitle, badges, status \
  \           FROM d ORDER BY title NULLS LAST, ord LIMIT ?) z), json_build_array())) AS dreps, \
  \       json_build_object('total', (SELECT count(*)::int FROM g), 'items', \
  \         COALESCE((SELECT json_agg(to_json(z)) FROM ( \
  \           SELECT kind, tx_hash, g.index, title, subtitle, badges, status \
  \           FROM g ORDER BY ord DESC LIMIT ?) z), json_build_array())) AS gov_actions, \
  \       json_build_object('total', (SELECT count(*)::int FROM p), 'items', \
  \         COALESCE((SELECT json_agg(to_json(z)) FROM ( \
  \           SELECT kind, hex, has_script, title, subtitle, badges, status \
  \           FROM p ORDER BY title NULLS LAST, ord LIMIT ?) z), json_build_array())) AS spos, \
  \       json_build_object('total', (SELECT count(*)::int FROM c), 'items', \
  \         COALESCE((SELECT json_agg(to_json(z)) FROM ( \
  \           SELECT kind, hex, has_script, title, subtitle, badges, status \
  \           FROM c ORDER BY ord LIMIT ?) z), json_build_array())) AS committee_members, \
  \       json_build_object('total', 0, 'items', json_build_array()) AS profiles, \
  \       json_build_object('total', 0, 'items', json_build_array()) AS attestations \
  \) x"


-- ---------------------------------------------------------------------------------------------

-- * The page composites

-- | The status expression, in ONE place.
--
-- @status@ is not a column: it is @registration_status@, @active_until_epoch@ and @is_active@
-- composed. The composition has to be byte-identical in the projection, the filter and the facet, or
-- the sidebar counts a population the list beside it excludes. It was already written twice; the
-- facet statement would have been the third copy, and 'searchSql' — which held the second copy —
-- now interpolates this instead of repeating it.
--
-- __The @unknown@ arm comes before the @is_active@ one, and the order is the whole point.__
-- @palmares.drep@ computes @is_active@ as @COALESCE(active_until >= tip_epoch, false)@, so a DRep
-- with no @drep_distr@ row — no deadline recorded by the ledger at all — falls out as @false@ and is
-- indistinguishable from one whose deadline has genuinely passed. Testing the null deadline FIRST is
-- what separates them. See 'Palmares.DomainTypes.Core.Types.DRepStatus' for the measurements.
drepStatusExpr :: Text
drepStatusExpr =
  "(CASE WHEN d.registration_status = 'retired' THEN 'retired' \
  \      WHEN d.active_until_epoch IS NULL THEN 'unknown' \
  \      WHEN d.is_active THEN 'active' ELSE 'inactive' END)"

-- | The statuses a request actually selects, default included.
--
-- Exported because the facet statement has to re-apply EXACTLY the predicate the page applied,
-- down to the default. A facet that assumed \"no status given\" meant \"every status\" would count
-- the 511 retired DReps into the anchor and language facets, which the page then does not show.
-- @unknown@ is in the default set DELIBERATELY. Those 90 preprod DReps were on the default page
-- before, labelled @inactive@; leaving the new value out of the default would have dropped 90
-- registered DReps off the page in order to stop mislabelling 21 of them, which is worse than
-- either label. With it in, the change is a pure relabel: the default page's population is
-- unchanged, the sidebar gains a row, and nothing is claimed that is not known.
effectiveDRepStatus :: DRepFilter -> [DRepStatus]
effectiveDRepStatus f
  | null (drepFilterStatus f) = [DRepActive, DRepInactive, DRepUnknown]
  | otherwise = drepFilterStatus f

-- | Every status 'drepStatusExpr' can produce: the facet universe.
--
-- @reserved@ is absent on purpose. 'DRepStatus' carries it for the two reserved ledger options,
-- which have no @drep_registration@ row, never enter @\/dreps@ (D-20), and therefore can never be
-- a facet count. Measured: these four sum to 805 — 294 registered and 511 retired — against 812
-- credentials in @drep_hash@, the other 7 being the never-registered ones 'drepWhere' excludes
-- unconditionally. Of the 294, 90 carry no ledger deadline and so land in @unknown@; the split
-- between @active@ and @inactive@ is over the remaining 204.
registeredDRepStatuses :: [DRepStatus]
registeredDRepStatuses = [DRepActive, DRepInactive, DRepUnknown, DRepRetired]

-- | The explorer's facet block, decoded from one statement.
--
-- Not a @QueryResponses@ DTO: these four keys are a private contract between the statement below
-- and this decode, the way 'Freshness' is. What the WIRE calls them is
-- 'DRepExplorerPageResponse''s business.
data DRepFacets = DRepFacets
  { facetStatus :: [(DRepStatus, Int)],
    facetAnchor :: [(AnchorStatus, Int)],
    facetLanguage :: [(Text, Int)],
    facetPower :: [PowerBucket]
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "facet", CamelToSnake]] DRepFacets

-- | The facet statement and its parameters, in placeholder order.
--
-- Split from 'drepFacetsQuery' as a pure function so that @UnitTests.QueryHardening@ can assert
-- the placeholder count against the parameter count without a database — the same check it already
-- runs over 'drepWhere'. Nine parameter groups in one bind list is precisely where an off-by-one
-- lives, and postgresql-simple only reports it at run time.
--
-- __One pass of the expensive join.__ @base@ is @MATERIALIZED@ deliberately: the join behind it is
-- this endpoint's entire cost (measured 1805 ms cold, 1006 ms warm, 805 rows), and four facet
-- subqueries over an inlined CTE would pay for it four times. Materialized it is paid once and the
-- aggregations run over at most 812 rows already in memory — measured, the whole statement is
-- 391 ms warm, which is the join plus nothing.
--
-- Each enumerated facet DROPS ITS OWN predicate and keeps the other two. The power histogram keeps
-- all three, because it is a range control rather than a checkbox list: its counts sum to the page
-- total, which is also what makes them readable next to it.
drepFacetsSql :: DRepFilter -> (Text, [PersistValue])
drepFacetsSql f = (sql, params)
  where
    -- The base predicate is the request's, MINUS the three facet dimensions. Status is set to the
    -- three real values rather than to [] because [] means "the default two" (effectiveDRepStatus).
    (baseWhere, baseParams) =
      drepWhere
        f
          { drepFilterStatus = registeredDRepStatuses,
            drepFilterAnchorStatus = [],
            drepFilterLanguage = Nothing
          }
    (statusSql, statusPs) = inFacet "status" (map jsonTag (effectiveDRepStatus f))
    (anchorSql, anchorPs) = inFacet "anchor_status" (map jsonTag (drepFilterAnchorStatus f))
    (langSql, langPs) = case drepFilterLanguage f of
      Nothing -> ("TRUE", [])
      Just l -> ("language = ?", [toPersistValue l])

    -- Placeholders expanded, never bound as an array, for the reason 'drepWhere' gives. "TRUE" on
    -- the empty list keeps the four subqueries textually identical whether or not a dimension is
    -- filtered, so the bind list below cannot shift.
    inFacet col vs
      | null vs = ("TRUE", [])
      | otherwise =
          ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
            map toPersistValue vs
          )

    params =
      concat
        [ baseParams,
          -- the status facet: its own clause dropped
          anchorPs,
          langPs,
          -- the anchor facet
          statusPs,
          langPs,
          -- the language facet
          statusPs,
          anchorPs,
          -- the histogram: all three kept
          statusPs,
          anchorPs,
          langPs
        ]

    sql =
      "WITH base AS MATERIALIZED ( SELECT "
        <> drepStatusExpr
        <> " AS status, a.verdict AS anchor_status, d.language, m.voting_power "
        <> drepFrom
        <> baseWhere
        <> " ) SELECT row_to_json(x)::text FROM ( SELECT \
           \ ( SELECT COALESCE(json_agg(json_build_array(status, n) ORDER BY status), '[]'::json) \
           \     FROM ( SELECT status, count(*)::int AS n FROM base \
           \             WHERE "
        <> anchorSql
        <> " AND "
        <> langSql
        <> " GROUP BY 1 ) q ) AS status, \
           \ ( SELECT COALESCE(json_agg(json_build_array(anchor_status, n) \
           \                            ORDER BY n DESC, anchor_status), '[]'::json) \
           \     FROM ( SELECT anchor_status, count(*)::int AS n FROM base \
           \             WHERE anchor_status IS NOT NULL AND "
        <> statusSql
        <> " AND "
        <> langSql
        <> " GROUP BY 1 ) q ) AS anchor, \
           \ ( SELECT COALESCE(json_agg(json_build_array(language, n) \
           \                            ORDER BY n DESC, language), '[]'::json) \
           \     FROM ( SELECT language, count(*)::int AS n FROM base \
           \             WHERE language IS NOT NULL AND "
        <> statusSql
        <> " AND "
        <> anchorSql
        <> " GROUP BY 1 ) q ) AS language, \
           \ ( SELECT COALESCE(json_agg(json_build_object('lo', lo, 'hi', hi, 'count', n) \
           \                            ORDER BY lo), '[]'::json) \
           \     FROM ( SELECT b.lo, b.hi, count(p.voting_power)::int AS n \
           \              FROM (VALUES (0::bigint, 1::bigint), \
           \                           (1, 1000000000), \
           \                           (1000000000, 10000000000), \
           \                           (10000000000, 100000000000), \
           \                           (100000000000, 1000000000000), \
           \                           (1000000000000, NULL::bigint)) AS b(lo, hi) \
           \              LEFT JOIN base p ON p.voting_power >= b.lo \
           \                              AND (b.hi IS NULL OR p.voting_power < b.hi) \
           \                              AND "
        <> statusSql
        <> " AND "
        <> anchorSql
        <> " AND "
        <> langSql
        <> " GROUP BY b.lo, b.hi ) q ) AS power \
           \ ) x"

-- | The explorer's four facet lists. 'Nothing' is unreachable: the outer @SELECT@ has no @FROM@.
drepFacetsQuery :: DRepFilter -> SqlPersistT IO (Maybe DRepFacets)
drepFacetsQuery f = let (sql, params) = drepFacetsSql f in queryJson1 sql params

-- | Every scalar figure @\/pages\/dashboard@ publishes, from ONE statement.
--
-- A carrier, like 'DRepFacets': one @row_to_json@ object, one decode, and the response's own field
-- names stay 'RestAPI''s business.
data DashboardTotals = DashboardTotals
  { totalsTotalActions :: Int,
    totalsActionsInFlight :: Int,
    totalsActionsByType :: [(GovActionType, Int)],
    totalsActionsByState :: [(GovActionState, Int)],
    totalsTreasuryRequestedLovelace :: Integer,
    totalsTreasuryEnactedLovelace :: Integer,
    totalsPowerEpoch :: Maybe Int,
    totalsDrepPowerLovelace :: Integer,
    totalsAlwaysAbstainLovelace :: Integer,
    totalsAlwaysNoConfidenceLovelace :: Integer
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "totals", CamelToSnake]] DashboardTotals

-- | The dashboard's scalar figures: one statement, one group per subquery, one scan per relation.
--
-- __The three CTEs are the design, not tidiness.__ @palmares.gov_action@ publishes @votes_cast@ as
-- a correlated count over @public.voting_procedure@'s 3.24 M rows; measured, selecting it for all
-- 131 actions costs __41.7 s__, while selecting the three columns this statement actually needs
-- costs __213 ms__ because PostgreSQL prunes the view's unused targetlist. Naming the columns is
-- what keeps that pruning available, so this statement must never grow a @SELECT *@. The whole
-- thing measures 100 ms.
--
-- @ratified@ is 0 on preprod and every type and state is still emitted, through a @LEFT JOIN@ from
-- a literal list, for the reason 'DRepMetrics' gives about its seven action types: a missing row
-- reads as \"no such thing\" where the truth is \"none of them\".
--
-- The parked-stake figures are read at @sync_state.drep_distr_epoch@, INSIDE the statement, rather
-- than at an epoch bound in from Haskell: the ledger writes the distribution one epoch behind the
-- tip, and binding the tip would publish three zeroes for the first blocks of every epoch.
dashboardTotalsQuery :: SqlPersistT IO (Maybe DashboardTotals)
dashboardTotalsQuery =
  queryJson1
    "WITH ga AS MATERIALIZED ( \
    \  SELECT g.state, g.action_type, g.last_votable_epoch FROM palmares.gov_action g ), \
    \ tw AS MATERIALIZED ( \
    \  SELECT w.amount, w.enacted_epoch FROM palmares.treasury_withdrawal w ), \
    \ pw AS MATERIALIZED ( \
    \  SELECT p.target_kind, p.amount FROM palmares.drep_epoch_power p \
    \   WHERE p.epoch_no = (SELECT s.drep_distr_epoch FROM palmares.sync_state s) ) \
    \ SELECT row_to_json(x)::text FROM ( SELECT \
    \   (SELECT count(*)::int FROM ga) AS total_actions, \
    \   (SELECT count(*)::int FROM ga \
    \     WHERE ga.last_votable_epoch >= (SELECT s.epoch_no FROM palmares.sync_state s)) \
    \     AS actions_in_flight, \
    \   (SELECT COALESCE(json_agg(json_build_array(t.k, COALESCE(c.n, 0)) ORDER BY t.k), '[]'::json) \
    \      FROM (VALUES ('hard_fork_initiation'), ('info_action'), ('new_committee'), \
    \                   ('new_constitution'), ('no_confidence'), ('parameter_change'), \
    \                   ('treasury_withdrawals')) AS t(k) \
    \      LEFT JOIN ( SELECT lower(regexp_replace(action_type::text, \
    \                                              '([a-z0-9])([A-Z])', '\\1_\\2', 'g')) AS k, \
    \                         count(*)::int AS n FROM ga GROUP BY 1 ) c ON c.k = t.k) \
    \     AS actions_by_type, \
    \   (SELECT COALESCE(json_agg(json_build_array(t.k, COALESCE(c.n, 0)) ORDER BY t.k), '[]'::json) \
    \      FROM (VALUES ('proposed'), ('ratified'), ('enacted'), ('expired'), ('dropped')) AS t(k) \
    \      LEFT JOIN ( SELECT state AS k, count(*)::int AS n FROM ga GROUP BY 1 ) c ON c.k = t.k) \
    \     AS actions_by_state, \
    \   (SELECT COALESCE(sum(amount), 0)::bigint FROM tw) AS treasury_requested_lovelace, \
    \   (SELECT COALESCE(sum(amount) FILTER (WHERE enacted_epoch IS NOT NULL), 0)::bigint FROM tw) \
    \     AS treasury_enacted_lovelace, \
    \   (SELECT s.drep_distr_epoch FROM palmares.sync_state s) AS power_epoch, \
    \   (SELECT COALESCE(sum(amount) FILTER (WHERE target_kind = 'drep'), 0)::bigint FROM pw) \
    \     AS drep_power_lovelace, \
    \   (SELECT COALESCE(sum(amount) FILTER (WHERE target_kind = 'always_abstain'), 0)::bigint \
    \      FROM pw) AS always_abstain_lovelace, \
    \   (SELECT COALESCE(sum(amount) FILTER (WHERE target_kind = 'always_no_confidence'), 0)::bigint \
    \      FROM pw) AS always_no_confidence_lovelace \
    \ ) x"
    []

-- | DRep participation, epoch by epoch, over the last @n@ epochs ending at the tip.
--
-- __This goes around @palmares.vote@ on purpose__, and the precedent is @palmares.gov_action@'s
-- own @votes_cast@, which goes around it for the same reason and records the same kind of
-- measurement in its comment. @palmares.vote@ computes window functions over all 3.24 M
-- voting-procedure rows — preprod's epoch-187 committee stress test is 3,243,802 of them — so a
-- per-epoch aggregate through it costs __1213 ms__. Reached through
-- @gov_idx_voting_procedure_drep@, the partial index on @drep_voter@, the identical answer costs
-- __4.6 ms__: measured side by side, the same 19 epochs with the same voter and vote counts.
--
-- The denominator is the LEFT side, so an epoch in which nobody voted is a row with 0 and a rate
-- of 0 rather than a gap — measured, epoch 311 is exactly that. The ORDER is ascending because
-- the series is read as a chart.
listEpochParticipation :: Int -> SqlPersistT IO [EpochParticipationPoint]
listEpochParticipation epochs =
  queryJson
    "SELECT row_to_json(x)::text FROM ( \
    \  SELECT e.epoch_no AS epoch, e.with_power AS dreps_with_power, \
    \         COALESCE(v.voters, 0) AS dreps_voted, COALESCE(v.votes, 0) AS votes_cast, \
    \         CASE WHEN e.with_power = 0 THEN NULL \
    \              ELSE COALESCE(v.voters, 0)::float8 / e.with_power END AS participation_rate \
    \  FROM ( SELECT p.epoch_no, count(*) FILTER (WHERE p.amount > 0)::int AS with_power \
    \           FROM palmares.drep_epoch_power p \
    \          WHERE p.target_kind = 'drep' \
    \            AND p.epoch_no >  (SELECT s.epoch_no FROM palmares.sync_state s) - ? \
    \            AND p.epoch_no <= (SELECT s.epoch_no FROM palmares.sync_state s) \
    \          GROUP BY 1 ) e \
    \  LEFT JOIN ( SELECT b.epoch_no, \
    \                     count(DISTINCT v.drep_voter)::int AS voters, \
    \                     count(*)::int AS votes \
    \                FROM public.voting_procedure v \
    \                JOIN public.tx t ON t.id = v.tx_id \
    \                JOIN public.block b ON b.id = t.block_id \
    \               WHERE v.drep_voter IS NOT NULL \
    \                 AND b.epoch_no > (SELECT s.epoch_no FROM palmares.sync_state s) - ? \
    \               GROUP BY 1 ) v ON v.epoch_no = e.epoch_no \
    \  ORDER BY e.epoch_no ASC \
    \) x"
    [toPersistValue epochs, toPersistValue epochs]

-- ---------------------------------------------------------------------------------------------

-- * GET /delegations

-- | The ordering each @order_by@ value means. Closed and total, as 'drepSortSpec' is.
--
-- @at@ sorts on the SLOT, not the timestamp: two delegations in one block share a timestamp and
-- not a slot ordering, and the tiebreaker has to break ties rather than hide them.
delegationSortSpec :: DelegationsOrderBy -> SortSpec
delegationSortSpec = \case
  DelegationsOrderByAt -> SortSpec "dv.slot_no" False tie
  DelegationsOrderByLovelace -> SortSpec "es.amount" True tie
  DelegationsOrderByStakeAddress -> SortSpec "dv.stake_address" False tie
  where
    tie = "dv.addr_id"

-- | The SAME sort, named over the page subquery's own columns instead of the base tables'.
--
-- It exists because 'listDelegations' is the one list query built in two levels: the page is
-- chosen and ordered in a subquery, and the DRep's name is joined on ABOVE it. __An ORDER BY
-- inside a subquery is not preserved through a join over it__, and PostgreSQL duly returned the
-- right five rows in hash-join order. MEASURED, by the smoke suite:
-- @\/delegations?order_by=at&sort_order=desc@ came back 136808533, 136808622, 136809426,
-- 136766068, 136815403 — the correct five newest delegations, in no order at all.
--
-- A second spec rather than a prefix parameter on the first, because the two are not a
-- substitution: @es.amount@ inside is @lovelace@ outside, a column the subquery itself named.
delegationOuterSortSpec :: DelegationsOrderBy -> SortSpec
delegationOuterSortSpec = \case
  DelegationsOrderByAt -> SortSpec "p.slot_no" False tie
  DelegationsOrderByLovelace -> SortSpec "p.lovelace" True tie
  DelegationsOrderByStakeAddress -> SortSpec "p.stake_address" False tie
  where
    tie = "p.addr_id"

-- | Whether this row's delegation still counts, as ONE expression.
--
-- Used by the projection and by the @is_current@ filter alike, for the reason 'drepWhere'
-- spells out for @status@: a page must not be able to show a flag the filter would have excluded.
--
-- __This is @palmares.live_delegation@'s own predicate, inlined, and that is a performance
-- decision with a measurement behind it.__ The obvious shape — @LEFT JOIN palmares.live_delegation
-- ON addr_id AND drep_hash_id@ — makes the statement walk the DISTINCT-ON over
-- @palmares.vote_delegation@ TWICE, once for this page's rows and once inside that view, because
-- the view computes the same \"latest certificate per address\" set. Measured: 2,929 ms for a
-- 50-row page against 1,025 ms for this shape, and the two agree exactly — 2,304 addresses,
-- 2,015 current, 289 not, on both. That equality is checked after every change to either.
--
-- The equivalence is not a coincidence and is worth stating, because the duplication is the price:
-- @dv@ below and @live_delegation@ select the same latest row per address, so
-- @l.drep_hash_id = dv.drep_hash_id@ is implied by @l.addr_id = dv.addr_id@ and all that
-- @live_delegation@ adds is this deregistration check. If that view's predicate ever changes, THIS
-- LINE must change with it — and it has: both now compare CERTIFICATES by @(tx_id, cert_index)@
-- rather than epochs, because the epoch form cancelled a delegation using a deregistration that
-- happened before it in the same epoch. @sql\/010_gov_views.sql@ carries the measurement; the
-- views smoke asserts the two still agree row for row, which is what makes the duplication safe.
delegationIsCurrentExpr :: Text
delegationIsCurrentExpr =
  "NOT EXISTS (SELECT 1 FROM public.stake_deregistration sd \
  \            WHERE sd.addr_id = dv.addr_id \
  \              AND (sd.tx_id, sd.cert_index) > (dv.tx_id, dv.cert_index))"

-- | The FROM clause the page and the count share, for F-17's reason.
--
-- Only the columns the filters and the orderings touch. The identity decoration — the target's
-- credential and its published name — is joined OUTSIDE the paged subquery in 'listDelegations',
-- which is also measured: joining @palmares.drep@ inside made the planner re-scan it once per
-- candidate row (once per current delegation, +1.37 s on a 50-row page). Neither join can change
-- cardinality, @drep_hash@ being PK-joined and @palmares.drep@ having exactly one row per
-- @drep_hash_id@ (measured: 812 rows, 812 distinct ids), so the count stays honest.
delegationFrom :: Text
delegationFrom =
  " FROM ( SELECT DISTINCT ON (addr_id) addr_id, stake_address, drep_hash_id, target_kind, \
  \               slot_no, epoch_no, delegated_at, tx_hash, tx_id, cert_index \
  \        FROM palmares.vote_delegation \
  \        ORDER BY addr_id, slot_no DESC, tx_index DESC, cert_index DESC ) dv \
  \ LEFT JOIN ( SELECT addr_id, amount FROM public.epoch_stake \
  \             WHERE epoch_no = (SELECT max(epoch_no) FROM public.epoch_stake) ) es \
  \   ON es.addr_id = dv.addr_id "

-- | The @WHERE@ fragment and its parameters, in placeholder order.
delegationWhere :: DelegationFilter -> (Text, [PersistValue])
delegationWhere f =
  let clauses =
        concat
          [ [("(" <> delegationIsCurrentExpr <> ") = ?", [toPersistValue (delegationFilterIsCurrent f)])],
            targetClause,
            inClause "dv.stake_address" (delegationFilterStakeAddresses f),
            one "dv.delegated_at >= ?" (delegationFilterFrom f),
            one "dv.delegated_at <= ?" (delegationFilterTo f),
            one "es.amount >= ?" (delegationFilterMinLovelace f)
          ]
   in ("WHERE " <> T.intercalate " AND " (map fst clauses), concatMap snd clauses)
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

    inClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
              map toPersistValue vs
            )
          ]

    -- ONE clause with up to two OR-arms, not two AND'd clauses: a client naming a credential and
    -- `drep_always_abstain` in the same request means "either of these targets", and AND'ing them
    -- would return nothing. Both lists empty yields no clause at all, which is "any target".
    --
    -- The credential arm resolves through `drep_hash` rather than comparing `dv.drep_hash_id`
    -- directly, because the client sent an identifier and not an internal row id. `drep_hash` is
    -- 814 rows, so the semi-join is a hashed scan and costs nothing measurable.
    targetClause =
      case ( delegationFilterDrepHex f,
             delegationFilterReservedTargets f
           ) of
        ([], []) -> []
        (hexes, reserved) ->
          let arms =
                [ ( "dv.drep_hash_id IN (SELECT h.id FROM public.drep_hash h WHERE h.raw IN ("
                      <> T.intercalate ", " (map (const "decode(?, 'hex')") hexes)
                      <> "))",
                    map toPersistValue hexes
                  )
                  | not (null hexes)
                ]
                  <> [ ( "dv.target_kind IN (" <> T.intercalate ", " (map (const "?") reserved) <> ")",
                         map toPersistValue reserved
                       )
                       | not (null reserved)
                     ]
           in [("(" <> T.intercalate " OR " (map fst arms) <> ")", concatMap snd arms)]

-- | One page of delegations, with a total over the same predicate.
--
-- The page is selected first and decorated second, per 'delegationFrom'.
listDelegations ::
  DelegationFilter ->
  (DelegationsOrderBy, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page DelegationRecord)
listDelegations f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> delegationProjection
          <> " FROM ( SELECT dv.addr_id, dv.stake_address, dv.drep_hash_id, dv.target_kind, \
             \               dv.slot_no, dv.epoch_no, dv.delegated_at, dv.tx_hash, \
             \               es.amount AS lovelace, ("
          <> delegationIsCurrentExpr
          <> ") AS is_current "
          <> delegationFrom
          <> whereSql
          <> " "
          <> orderClause (delegationSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) p \
             \ JOIN public.drep_hash dh ON dh.id = p.drep_hash_id \
             \ LEFT JOIN palmares.drep d ON d.drep_hash_id = p.drep_hash_id "
          <> orderClause (delegationOuterSortSpec ob) so
          <> " ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> delegationFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    (whereSql, params) = delegationWhere f

-- | The projection list. Keys are 'DelegationRecord''s wire names, plus the three the DTO's
-- 'FromJSON' consumes to DERIVE @target@ and does not republish.
delegationProjection :: Text
delegationProjection =
  " p.stake_address, p.target_kind, \
  \ encode(dh.raw, 'hex') AS target_hex, \
  \ COALESCE(dh.has_script, FALSE) AS target_has_script, \
  \ d.given_name AS target_name, \
  \ p.lovelace, \
  \ json_build_object('slot', p.slot_no, 'epoch', p.epoch_no, \
  \                   'time', (p.delegated_at AT TIME ZONE 'UTC'), \
  \                   'tx_hash', encode(p.tx_hash, 'hex')) AS at, \
  \ p.is_current "

-- ---------------------------------------------------------------------------------------------

-- * GET /committee

-- | The committee in force, with its seats, as one JSON object.
--
-- __Deliberately NOT read through @palmares.committee_member@, and the reason is measured.__ That
-- view resolves each seat's hot key with a @LEFT JOIN LATERAL@ that joins @committee_hash@ INSIDE
-- the subquery and sorts before its @LIMIT 1@; the planner answers it by building all 648,814
-- @committee_hash@ rows and discarding all but one, once per seat. Measured, for the three current
-- seats: 917 ms through that shape against 0.13 ms for the shape below, which takes the @LIMIT 1@
-- on @committee_registration@ FIRST and then does a single primary-key lookup. End to end the
-- route went from 2,701 ms to 692 ms, serving byte-identical JSON.
--
-- The view could not have served this route anyway: @authorized_at@ and @resigned_at@ need
-- @committee_registration@ and @committee_de_registration@ directly, which the view does not
-- publish. Reading @hot_hash@ and @status@ from the same two visits is strictly less work than
-- visiting them twice — and @status@ is the view's own predicate verbatim, an existence check on
-- @committee_de_registration@, which is what keeps the two definitions one definition. If that
-- view's @status@ CASE gains an arm, this must gain it too.
--
-- @votes_cast@ reads @public.voting_procedure@ rather than @palmares.vote@, and that is the same
-- kind of measurement: @palmares.vote@ joins @palmares.cc_cold_interval@, whose @lead()@ window
-- runs over all 648,767 @committee_registration@ rows whatever the qual, so even an SPO-only
-- count through it costs 1,064 ms where the direct read costs 103 ms. Counting through
-- @voter_cold_hash@ as the plan suggested is worse still — that column is not in @palmares.vote@'s
-- @PARTITION BY@, so it pays a full pass: 4,252 ms for one member, against 2,413 ms for the
-- partition-column qual and 105 ms here.
--
-- The hot-key attribution drops @cc_cold_interval@'s interval check and keeps only
-- @cr.tx_id \<= vp.tx_id@ — a vote cannot belong to a registration made after it. The dropped half
-- guards against one hot key being registered under a second cold key later, and __measured, zero
-- of preprod's 648,766 hot keys is registered to more than one cold key__. The day one is, this
-- under-counts rotations and needs the @NOT EXISTS@ form of the interval back.
getCommittee :: SqlPersistT IO (Maybe CommitteeResponse)
getCommittee =
  queryJson1
    "SELECT row_to_json(x)::text FROM ( \
    \  WITH cur AS ( SELECT es.committee_id, es.epoch_no FROM public.epoch_state es \
    \                WHERE es.committee_id IS NOT NULL \
    \                ORDER BY es.epoch_no DESC, es.id DESC LIMIT 1 ), \
    \  votes AS ( SELECT cr.cold_key_id, count(DISTINCT vp.gov_action_proposal_id)::int AS votes_cast \
    \             FROM public.committee_registration cr \
    \             JOIN public.voting_procedure vp \
    \               ON vp.committee_voter = cr.hot_key_id AND cr.tx_id <= vp.tx_id \
    \             WHERE cr.cold_key_id IN ( SELECT cm.committee_hash_id \
    \                                       FROM public.committee_member cm \
    \                                       WHERE cm.committee_id = (SELECT committee_id FROM cur) ) \
    \             GROUP BY cr.cold_key_id ) \
    \  SELECT c.quorum_numerator::int AS quorum_numerator, \
    \         c.quorum_denominator::int AS quorum_denominator, \
    \         CASE WHEN ga.tx_hash IS NULL THEN NULL \
    \              ELSE encode(ga.tx_hash, 'hex') || '#' || ga.index END AS established_by, \
    \         cur.epoch_no AS epoch, \
    \         COALESCE( \
    \           ( SELECT json_agg(json_build_object( \
    \                      'cold_hash', encode(ch.raw, 'hex'), \
    \                      'cold_has_script', ch.has_script, \
    \                      'hot_hash', encode(hot.raw, 'hex'), \
    \                      'expiration_epoch', cm.expiration_epoch, \
    \                      'status', CASE WHEN dereg.tx_id IS NOT NULL THEN 'resigned' ELSE 'active' END, \
    \                      'votes_cast', COALESCE(v.votes_cast, 0), \
    \                      'authorized_at', \
    \                        CASE WHEN rb.id IS NULL THEN NULL \
    \                             ELSE json_build_object('slot', rb.slot_no, 'epoch', rb.epoch_no, \
    \                                    'time', (rb.\"time\" AT TIME ZONE 'UTC'), \
    \                                    'tx_hash', encode(rtx.hash, 'hex')) END, \
    \                      'resigned_at', \
    \                        CASE WHEN db.id IS NULL THEN NULL \
    \                             ELSE json_build_object('slot', db.slot_no, 'epoch', db.epoch_no, \
    \                                    'time', (db.\"time\" AT TIME ZONE 'UTC'), \
    \                                    'tx_hash', encode(dtx.hash, 'hex')) END) \
    \                     ORDER BY ch.raw) \
    \             FROM public.committee_member cm \
    \             JOIN public.committee_hash ch ON ch.id = cm.committee_hash_id \
    \             LEFT JOIN LATERAL ( SELECT cr.hot_key_id, cr.tx_id \
    \                                 FROM public.committee_registration cr \
    \                                 WHERE cr.cold_key_id = cm.committee_hash_id \
    \                                 ORDER BY cr.tx_id DESC, cr.cert_index DESC LIMIT 1 ) reg ON TRUE \
    \             LEFT JOIN public.committee_hash hot ON hot.id = reg.hot_key_id \
    \             LEFT JOIN public.tx rtx ON rtx.id = reg.tx_id \
    \             LEFT JOIN public.block rb ON rb.id = rtx.block_id \
    \             LEFT JOIN LATERAL ( SELECT dr.tx_id \
    \                                 FROM public.committee_de_registration dr \
    \                                 WHERE dr.cold_key_id = cm.committee_hash_id \
    \                                 ORDER BY dr.tx_id DESC, dr.cert_index DESC LIMIT 1 ) dereg ON TRUE \
    \             LEFT JOIN public.tx dtx ON dtx.id = dereg.tx_id \
    \             LEFT JOIN public.block db ON db.id = dtx.block_id \
    \             LEFT JOIN votes v ON v.cold_key_id = cm.committee_hash_id \
    \             WHERE cm.committee_id = cur.committee_id ), '[]'::json) AS members \
    \  FROM cur \
    \  JOIN public.committee c ON c.id = cur.committee_id \
    \  LEFT JOIN palmares.gov_action ga ON ga.gov_action_id = c.gov_action_proposal_id \
    \) x"
    []

-- ---------------------------------------------------------------------------------------------

-- * GET /spos

-- | The ordering each @order_by@ value means. Closed and total.
--
-- @voting_power@ sorts on the same @COALESCE@ the projection publishes and the @min_voting_power@
-- filter compares, so a pool cannot sort as absent and read as zero. @pool_id@ sorts on
-- @pool_hash.view@, which is the ONE place this endpoint trusts db-sync's own bech32 — verified
-- byte-identical to 'poolIdBech32' for the top pool by power, and ordering by it is ordering by
-- the string the response publishes rather than by raw bytes, which is what a client asked for.
spoSortSpec :: SPOsOrderBy -> SortSpec
spoSortSpec = \case
  SPOsOrderByVotingPower -> SortSpec "COALESCE(ps.voting_power, 0)" False tie
  SPOsOrderByVotesCast -> SortSpec "COALESCE(vc.votes_cast, 0)" False tie
  SPOsOrderByPoolId -> SortSpec "ph.view" False tie
  where
    tie = "ph.id"

-- | The FROM clause the page and the count share.
--
-- The vote counts are ONE pre-aggregated pass over @public.voting_procedure@ — 90 SPO vote rows
-- behind a partial index — rather than a per-pool subquery, which over 510 pools would be 510
-- passes. Not through @palmares.vote@: see 'getCommittee' for the 1,064 ms that costs.
--
-- The @off_chain_pool_data@ join has 0 rows on preprod and is here so @ticker@ fills itself if the
-- fetcher is ever enabled. @DISTINCT ON@ because that table is one row per metadata FETCH, not per
-- pool.
spoFrom :: Text
spoFrom =
  " FROM public.pool_stat ps \
  \ JOIN public.pool_hash ph ON ph.id = ps.pool_hash_id \
  \ LEFT JOIN ( SELECT vp.pool_voter AS pool_hash_id, \
  \                    count(DISTINCT vp.gov_action_proposal_id)::int AS votes_cast \
  \             FROM public.voting_procedure vp \
  \             WHERE vp.pool_voter IS NOT NULL \
  \             GROUP BY vp.pool_voter ) vc ON vc.pool_hash_id = ph.id \
  \ LEFT JOIN ( SELECT DISTINCT ON (o.pool_id) o.pool_id, o.ticker_name \
  \             FROM public.off_chain_pool_data o \
  \             ORDER BY o.pool_id, o.id DESC ) ocpd ON ocpd.pool_id = ph.id "

-- | The @WHERE@ fragment and its parameters.
--
-- The epoch pin is unconditional: @pool_stat@ holds 99,872 rows across every epoch since the
-- Shelley era, and without it the endpoint would publish one row per pool per epoch.
spoWhere :: SPOFilter -> (Text, [PersistValue])
spoWhere f =
  let clauses =
        concat
          [ [("ps.epoch_no = (SELECT max(epoch_no) FROM public.pool_stat)", [])],
            one "COALESCE(ps.voting_power, 0) >= ?" (spoFilterMinVotingPower f),
            one "COALESCE(vc.votes_cast, 0) >= ?" (spoFilterMinVotesCast f),
            -- A semi-join and not an EXISTS: pool_stat carries no index on epoch_no, so a
            -- correlated EXISTS would scan all 99,872 rows once per candidate pool. This form
            -- scans them once and hashes the result.
            one
              "ps.pool_hash_id IN (SELECT p2.pool_hash_id FROM public.pool_stat p2 \
              \ WHERE p2.epoch_no = ? AND p2.voting_power > 0)"
              (spoFilterActiveInEpoch f)
          ]
   in ("WHERE " <> T.intercalate " AND " (map fst clauses), concatMap snd clauses)
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

-- | One page of stake pools, with a total over the same predicate.
listSPOs :: SPOFilter -> (SPOsOrderBy, SortOrder) -> (Limit, Offset) -> SqlPersistT IO (Page SPOSummary)
listSPOs f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> spoProjection
          <> spoFrom
          <> whereSql
          <> " "
          <> orderClause (spoSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> spoFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    (whereSql, params) = spoWhere f

-- | The projection list. @hash@ is consumed by 'SPOSummary''s 'FromJSON' to derive @pool_id@ and
-- is not republished.
--
-- @participation_rate@ is a literal NULL: see 'SPOSummary' for why a number with no catalog
-- formula is not published here.
spoProjection :: Text
spoProjection =
  " encode(ph.hash_raw, 'hex') AS hash, \
  \ NULLIF(ocpd.ticker_name, '') AS ticker, \
  \ COALESCE(ps.voting_power, 0) AS voting_power, \
  \ ps.epoch_no AS voting_power_epoch, \
  \ ps.number_of_delegators::int AS delegator_count, \
  \ COALESCE(vc.votes_cast, 0) AS votes_cast, \
  \ NULL::float8 AS participation_rate "

-- ---------------------------------------------------------------------------------------------

-- * GET /treasury-withdrawals

-- | The ordering each @order_by@ value means. Closed and total.
--
-- The tiebreaker is TWO columns, unlike every other sort spec here, and it has to be: the
-- @palmares.treasury_withdrawal@ view does not publish @treasury_withdrawal.id@, so no single
-- column identifies a row. @(gov_action_id, stake_address_id)@ does — measured, 83 rows and 83
-- distinct pairs — and without both, the 82 rows sharing @enacted_epoch IS NULL@ would come back
-- in any order on any page.
--
-- @NULLS LAST@ on @enacted_epoch@ because an un-enacted withdrawal has no enactment epoch, not a
-- low one. On preprod that means the whole default page is decided by the tiebreaker.
withdrawalSortSpec :: TreasuryWithdrawalsOrderBy -> SortSpec
withdrawalSortSpec = \case
  TreasuryWithdrawalsOrderByAmount -> SortSpec "w.amount" False tie
  TreasuryWithdrawalsOrderByEnactedEpoch -> SortSpec "w.enacted_epoch" True tie
  where
    tie = "w.gov_action_id ASC, w.stake_address_id"

-- | The FROM clause the page and the count share.
--
-- The join to @palmares.gov_action@ is what supplies the action's identity and title, and going
-- through the view rather than @off_chain_vote_gov_action_data@ directly is the point: that table
-- carries db-sync 13.7.x's duplicate child rows, and joining it raw turns 83 withdrawals into 86.
-- The view's own @DISTINCT ON@ pins it. Measured: 83 rows and 3 titles through the view, 86 rows
-- through the raw join.
withdrawalFrom :: Text
withdrawalFrom =
  " FROM palmares.treasury_withdrawal w \
  \ JOIN palmares.gov_action g ON g.gov_action_id = w.gov_action_id "

-- | The @WHERE@ fragment and its parameters.
withdrawalWhere :: TreasuryWithdrawalFilter -> (Text, [PersistValue])
withdrawalWhere f =
  let clauses =
        concat
          [ inClause
              "encode(g.tx_hash, 'hex') || '#' || g.index"
              (map unGovActionId (withdrawalFilterGovActionIds f)),
            inClause "w.stake_address" (withdrawalFilterBeneficiaries f),
            one "w.enacted_epoch >= ?" (withdrawalFilterEnactedFromEpoch f),
            one "w.enacted_epoch <= ?" (withdrawalFilterEnactedToEpoch f),
            one "w.amount >= ?" (withdrawalFilterMinAmount f),
            one "w.amount <= ?" (withdrawalFilterMaxAmount f)
          ]
   in ( if null clauses then "" else "WHERE " <> T.intercalate " AND " (map fst clauses),
        concatMap snd clauses
      )
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

    inClause col vs
      | null vs = []
      | otherwise =
          [ ( col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")",
              map toPersistValue vs
            )
          ]

-- | One page of treasury withdrawals, with a total over the same predicate.
listTreasuryWithdrawals ::
  TreasuryWithdrawalFilter ->
  (TreasuryWithdrawalsOrderBy, SortOrder) ->
  (Limit, Offset) ->
  SqlPersistT IO (Page TreasuryWithdrawalRecord)
listTreasuryWithdrawals f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> withdrawalProjection
          <> withdrawalFrom
          <> whereSql
          <> " "
          <> orderClause (withdrawalSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> withdrawalFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    (whereSql, params) = withdrawalWhere f

-- | The projection list. @tx_hash@ and @index@ are consumed by the DTO's 'FromJSON' to derive
-- @gov_action_id@.
--
-- @enacted_at@ is an epoch-boundary chain point with no slot and no transaction hash, because the
-- ledger pays a withdrawal at an epoch boundary and there is nothing to point at. The same shape
-- 'listWithdrawals' publishes, so the list and the per-action view agree.
withdrawalProjection :: Text
withdrawalProjection =
  " encode(g.tx_hash, 'hex') AS tx_hash, g.index, \
  \ g.title AS gov_action_title, \
  \ w.stake_address AS beneficiary, \
  \ w.amount, w.enacted_epoch, \
  \ CASE WHEN w.enacted_epoch IS NULL THEN NULL \
  \      ELSE json_build_object( \
  \             'slot', NULL, 'epoch', w.enacted_epoch, 'tx_hash', NULL, \
  \             'time', (SELECT (min(b.time) AT TIME ZONE 'UTC') FROM public.block b \
  \                       WHERE b.epoch_no = w.enacted_epoch)) END AS enacted_at, \
  \ w.paid_heuristic "

-- ---------------------------------------------------------------------------------------------

-- * GET /activity

-- | Read a cursor back from its wire form, @\<sort_slot\>:\<tx_index\>:\<arm\>:\<item_index\>@.
--
-- The inverse of 'renderCursor', and the round trip is a unit test. A client never constructs one:
-- it echoes back the @next_cursor@ it was handed, so the only cursors this sees are ones this
-- service rendered — or ones somebody edited, which is why every component is validated instead of
-- being read with @read@ and allowed to fail in a thread.
--
-- @tx_index@ ACCEPTS A LEADING MINUS, and that is not defensive: the five epoch-boundary arms carry
-- @tx_index = -1@ and the treasury-enactment arm carries @-2@ (they have no transaction at all), so
-- a parser that rejected a negative component would refuse to page past the first ratified action.
parseCursor :: Text -> Either ErrorCode ActivityCursor
parseCursor t = case T.splitOn ":" t of
  [a, b, c, d] -> ActivityCursor <$> num a <*> num b <*> num c <*> num d
  _ -> Left InvalidCursor
  where
    -- Spelled out rather than left to `readMaybe` alone, which is Haskell's Read and therefore
    -- accepts a good deal more than an integer: a test found it taking " 1" (leading space), and it
    -- takes "(1)" and "1 " too. A cursor is a token this service ISSUED, so a client that got one
    -- back in a different spelling never constructed it legitimately, and accepting variants
    -- invites it to build its own. Digits, with an optional leading minus, and nothing else.
    num x
      | T.null digitsOf || not (T.all isDigit digitsOf) = Left InvalidCursor
      | otherwise = maybe (Left InvalidCursor) Right (readMaybe (T.unpack x) :: Maybe Int64)
      where
        digitsOf = fromMaybe x (T.stripPrefix "-" x)

-- | The projection list. Keys are 'ActivityRow''s wire names.
--
-- The four cursor components travel as columns, not as a concatenated string: 'ActivityRow''s
-- 'FromJSON' assembles them through 'renderCursor', so the wire format has exactly one definition
-- (D-31). A @||@ in SQL would be a second one, in another language, with no test between them.
activityProjection :: Text
activityProjection =
  " sort_slot, tx_index, arm, item_index, event_type, source, \
  \ json_build_object('slot', slot_no, 'epoch', epoch_no, \
  \                   'time', (block_time AT TIME ZONE 'UTC'), \
  \                   'tx_hash', tx_hash) AS at, \
  \ actor_id, target_id "

-- | The slot spans a page is attempted over, narrowest first. A span is a LOWER bound on
-- @sort_slot@, in slots, counted back from the cursor (or from the tip on a first page).
--
-- __Why a page is windowed at all, measured.__ @palmares.activity@ is eleven arms over 3.9 M rows,
-- 3.24 M of them votes, and @ORDER BY … DESC LIMIT 50@ with no lower bound makes PostgreSQL build
-- every one of those rows before the top-N sort discards all but 50: 4.6 s. The same page under the
-- first rung is 0.89 s, because the bound reaches the vote and committee arms' @block@ joins and
-- they read only that slot range. The window is the difference between a feed and a report.
--
-- __Why a ladder and not one span.__ A fixed 5-day span would report "end of feed" on any quieter
-- stretch of chain, which is a wrong answer, not a slow one. So a short page widens instead of
-- being published: 5 days, 50 days, 500 days, then no lower bound at all. The last rung is what
-- makes the endpoint TOTAL — it can always reach the genesis end — and it is the 4.6 s page, paid
-- by a client that has scrolled past everything else rather than on every request.
--
-- Climbing the ladder is CHEAP where it actually happens, which is the other half of the measured
-- case for it. A filter that matches little prunes most of the eleven arms to a one-time false
-- qual, so all four rungs together cost less than one unfiltered page: @event_type=\
-- committee_resigned@, which matches nothing on preprod, is 74 ms over the whole ladder, and
-- @event_type=gov_action_proposed@ fills its page in 21 ms.
activityWindows :: [Int64]
activityWindows = [432_000, 4_320_000, 43_200_000]

-- | Which way a page travels. @Older@ is the scroll, @Newer@ is the catch-up poll.
--
-- The direction decides THREE things together — the keyset comparison, the @ORDER BY@, and which
-- end of the window the cursor pins — and getting any one of them out of step with the other two
-- silently pages wrongly rather than failing. One value chooses all three.
data FeedDir = Older | Newer
  deriving stock (Show, Eq)

-- | The cursor's four columns, in order, as @palmares.activity@ names them.
--
-- ONE list, used by both the keyset row comparison and the @ORDER BY@. A keyset predicate and an
-- order that disagree do not fail — they return the wrong end of the range and still look like a
-- page — so the two are generated from the same source rather than written out twice.
cursorCols :: [Text]
cursorCols = ["sort_slot", "tx_index", "arm", "item_index"]

-- | The @WHERE@ fragment and its parameters: the filters, the keyset predicate, then the window.
--
-- @lo@ and @hi@ are the window's bounds on @sort_slot@. @hi@ is absent only on the ladder's last
-- rung travelling 'Older'; @lo@ is absent on every rung but the last.
activityWhere ::
  GovActivityFilter ->
  FeedDir ->
  Maybe ActivityCursor ->
  (Maybe Int64, Maybe Int64) ->
  (Text, [PersistValue])
activityWhere f dir mcur (lo, hi) =
  let clauses =
        concat
          [ inClause "event_type" (map jsonTag (govActivityFilterEventTypes f)),
            inClause "source" (map jsonTag (govActivityFilterSources f)),
            actorClause (govActivityFilterActors f),
            keyset mcur,
            window
          ]
   in ( if null clauses then "" else "WHERE " <> T.intercalate " AND " (map fst clauses),
        concatMap snd clauses
      )
  where
    inClause col vs
      | null vs = []
      | otherwise =
          [ (col <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")", map toPersistValue vs)
          ]

    -- Each requested actor contributes its value AS GIVEN and, when it decodes as a credential,
    -- its hex form too — one IN list, one to two entries per actor. Not a 400 on a value that does
    -- not decode: `actor_id` holds a bech32 STAKE ADDRESS on the delegation and proposal arms, so
    -- rejecting undecodable values would refuse every delegator in the feed.
    actorClause vs
      | null vs = []
      | otherwise =
          let cands = concatMap (\v -> v : maybe [] pure (anyVoterIdHex v)) vs
           in [ ( "actor_id IN (" <> T.intercalate ", " (map (const "?") cands) <> ")",
                  map toPersistValue cands
                )
              ]

    -- A ROW comparison, which is PostgreSQL's own lexicographic ordering over the tuple and
    -- therefore cannot disagree with the ORDER BY beside it. Spelled out as nested ORs it would be
    -- six clauses that have to be read carefully to see they say the same thing.
    keyset Nothing = []
    keyset (Just (ActivityCursor sl tx arm item)) =
      [ ( "(" <> T.intercalate ", " cursorCols <> ") " <> cmp <> " (?, ?, ?, ?)",
          map toPersistValue [sl, tx, arm, item]
        )
      ]
      where
        cmp = case dir of Older -> "<"; Newer -> ">"

    -- The window, as SCALAR bounds on sort_slot. The upper bound duplicates what the row
    -- comparison above already says, and it is not redundant to the PLANNER: a ROW comparison is
    -- opaque to it, so it cannot be pushed into the eleven arms, while `sort_slot <= ?` is and is
    -- what makes the vote arm read one slot range instead of all 3.24 M rows.
    --
    -- BOTH bounds are bound VALUES, including on a first page, where the upper bound is the chain
    -- tip that 'listActivity' reads first. Writing it as the scalar subquery
    -- `(SELECT max(slot_no) FROM public.block)` instead was MEASURED and is 4× worse: the first
    -- page took 3.7-4.4 s against 0.9 s for a cursor page of the same shape, because an InitPlan's
    -- value is unknown while the plan is chosen, so the arms are planned against a default
    -- selectivity guess. The extra round trip costs 2.5 ms and buys the same plan on every page.
    window =
      [("sort_slot >= ?", [toPersistValue v]) | Just v <- [lo]]
        <> [("sort_slot <= ?", [toPersistValue v]) | Just v <- [hi]]

-- | One page of the governance feed, newest first.
--
-- __Keyset, not offset, and the total is deliberately absent.__ @total@ is @null@ on every page
-- because counting the feed means a pass over all eleven arms — 3.9 M rows, of which 3.24 M are
-- the vote arm — and a feed is the one endpoint a client scrolls. F-17's rule says a total must
-- come from the same pass as the rows; a keyset page cannot give one, so it publishes none rather
-- than one that disagrees. @offset@ travels as 0 and is not a parameter: on a cursor feed an offset
-- would be a second, conflicting way to say where you are.
--
-- __A short page ends the feed.__ @next_cursor@ is the last row's cursor only when the page came
-- back full; fewer rows than asked for means the predicate is exhausted, and handing out a cursor
-- there would make a client poll forever for rows that cannot exist.
-- __Widening is safe because it is idempotent.__ A wider window returns the same newest rows plus
-- older ones, in the same order, so re-running a short page at the next rung cannot change what the
-- client has already seen. Only a page that came back FULL is published without widening.
-- __@since@ needs no ladder.__ Travelling 'Newer' both bounds are known from the start — the
-- client's cursor below, the chain tip above — so one statement answers it. A catch-up poll asks
-- for a narrow range by construction, and even a client returning after a month gets a range the
-- LIMIT caps. MEASURED: a @since@ page over the newest 5 days is 0.9 s, the same as the equivalent
-- @before@ page, because it is the same plan with the bounds swapped.
listActivity ::
  GovActivityFilter ->
  FeedDir ->
  Maybe ActivityCursor ->
  Limit ->
  SqlPersistT IO (Page ActivityRow)
listActivity f dir mcur lim = do
  -- NO PARALLEL WORKERS for this endpoint, and it is faster that way as well as safer.
  --
  -- PostgreSQL puts a parallel plan's shared memory in /dev/shm, sized from work_mem, and a plan
  -- over eleven arms asks for several 16 MB segments at once. On a container the tmpfs counts
  -- against the cgroup's memory limit, so the request fails as ENOSPC long before /dev/shm looks
  -- full. MEASURED: GET /activity?actor=… returned 503 with
  --   53100: could not resize shared memory segment … to 16777216 bytes: No space left on device
  -- while /dev/shm showed 1 MB of 256 MB used and the container 886 MB of its 2 GB. Raising
  -- shm_size alone does not fix it, because the wall is the cgroup, and the 2 GB limit and
  -- work_mem=32MB are the infra spec's own numbers — the Pi will run exactly these.
  --
  -- A feed page returns at most 100 rows from index-bounded arms, so there is nothing to
  -- parallelise. MEASURED with the workers off: a first page 875 -> 393 ms, an actor-filtered page
  -- 913 -> 433 ms, and the ladder's unbounded rung unchanged at 4.6 s. SET LOCAL scopes it to this
  -- transaction, so the ladder's four statements share it and no other endpoint is affected.
  rawExecute "SET LOCAL max_parallel_workers_per_gather = 0" []
  -- Where the cursor pins the window depends on the direction: travelling Older it is the upper
  -- bound (the tip, on a first page); travelling Newer it is the lower bound and the tip is the
  -- upper one. So the tip is read only when it is the bound actually needed — travelling Older
  -- from a cursor, the round trip would be for nothing.
  hi <- case (dir, mcur) of
    (Older, Just c) -> pure (cursorSortSlot c)
    _ -> tipSlot
  -- An ACTOR-filtered request skips the ladder and runs the last rung directly. Measured, and the
  -- rule is about `actor` specifically rather than about "is anything filtered":
  --
  --   * event_type is a CONSTANT in each arm's target list, so a filter on it collapses nine or ten
  --     of the eleven arms to a one-time false qual. The whole ladder is then cheaper than one
  --     unfiltered page: event_type=gov_action_proposed fills a page in 15 ms and
  --     event_type=committee_resigned, which matches nothing on preprod, answers in 10 ms. The
  --     ladder costs these nothing, so they keep it.
  --   * source prunes NOTHING today — every arm publishes 'governance', and 'attestation' arrives
  --     with the attestation schema. So ?source=governance IS the unfiltered feed, and a rule that
  --     sent any filtered request to the last rung made that request 8.3 s instead of 1.0 s. That
  --     measurement is why this reads `actor` and not `hasFilter`.
  --   * actor prunes nothing either, but an actor's events are genuinely sparse, so every rung
  --     comes back short and the ladder pays for all four before reaching the one that answers.
  --     MEASURED on a DRep with 18 events: 10.3 s up the ladder, 7.2 s straight to the last rung.
  --
  -- 7.2 s is slow for a timeline, and the honest answer is that /activity is not where an actor's
  -- own record belongs: /votes?voter_id=, /dreps/{id}/updates and /dreps/{id}/delegators serve it
  -- from indexed columns instead of from eleven arms' computed actor_id text.
  case dir of
    Newer -> onePage (cursorSortSlot <$> mcur, Just hi)
    Older
      | null (govActivityFilterActors f) -> go hi activityWindows
      | otherwise -> onePage (Nothing, Just hi)
  where
    go hi [] = onePage (Nothing, Just hi)
    go hi (w : ws) = do
      p <- onePage (Just (hi - w), Just hi)
      if length (pageItems p) >= lim then pure p else go hi ws

    onePage bounds = do
      let (whereSql, params) = activityWhere f dir mcur bounds
      items <-
        queryJson
          ( "SELECT row_to_json(x)::text FROM ( SELECT "
              <> activityProjection
              <> " FROM palmares.activity "
              <> whereSql
              <> " ORDER BY "
              <> T.intercalate ", " (map (<> (" " <> ord)) cursorCols)
              <> " LIMIT ? ) x"
          )
          (params <> [toPersistValue (fromIntegral lim :: Int64)])
      pure (Page items Nothing lim 0 (next items))

    ord = case dir of Older -> "DESC"; Newer -> "ASC"

    next rows
      | length rows < lim = Nothing
      | otherwise = Just (Cursor (activityRowCursor (last rows)))

-- | The chain tip's slot, for the first page's window. @0@ on an empty chain, which windows the
-- feed to nothing — correct, because an empty chain has no events.
tipSlot :: SqlPersistT IO Int64
tipSlot = do
  r <- rawSql "SELECT max(slot_no)::bigint FROM public.block" []
  pure (case r of (Single (Just n) : _) -> n; _ -> 0)

-- ---------------------------------------------------------------------------------------------

-- * GET /votes, in three stages

-- | Which optional joins one request actually needs.
--
-- Assembled per request rather than joined unconditionally, and that is the whole fix for this
-- endpoint. MEASURED on preprod's 3,243,802 committee vote rows, which is 97% of every vote on the
-- chain: the count through @palmares.vote@ with its four standing joins is __14.2 s__, and the same
-- count over @voting_procedure ⋈ gov_action@ alone is __1.09 s__. The difference is not the window
-- functions (3.5 s of it) — it is @tx ⋈ block@ (8.7 s) and @cc_cold_interval@ (9.5 s), neither of
-- which a count needs unless a filter or a sort reaches for them.
data VoteJoins = VoteJoins
  { -- | @tx@ and @block@: a time or epoch bound, or the latency sort
    vjBlock :: Bool,
    -- | @palmares.anchor@: the @anchor_status@ filter
    vjAnchor :: Bool,
    -- | @palmares.drep@: the @q@ filter, which searches the voter's published name
    vjDRep :: Bool,
    -- | @palmares.drep_epoch_power@: the @voting_power@ sort
    vjPower :: Bool,
    -- | @palmares.cc_cold_interval@: the @voter_id@ SORT, which orders by the published identity
    -- and therefore needs the committee's cold credential resolved. The voter_id FILTER does not —
    -- see 'voteBaseWhere'.
    vjCold :: Bool
  }

voteJoinsFor :: VoteFilter -> VotesOrderBy -> VoteJoins
voteJoinsFor f ob =
  VoteJoins
    { vjBlock =
        any
          id
          [ isJust (voteFilterFrom f),
            isJust (voteFilterTo f),
            isJust (voteFilterFromEpoch f),
            isJust (voteFilterToEpoch f),
            ob == VotesOrderByLatency
          ],
      vjAnchor = not (null (voteFilterAnchorStatus f)),
      vjDRep = isJust (voteFilterQ f),
      vjPower = ob == VotesOrderByVotingPower,
      vjCold = ob == VotesOrderByVoterId
    }

-- | The base @FROM@: @voting_procedure@, the action, and nothing else that was not asked for.
--
-- @palmares.gov_action@ is always joined and is an INNER join, as it was before. It does not
-- filter — every vote references a proposal and all 131 are in the view, measured: the count with
-- it is 3,243,802, exactly the committee row count check 030 asserts — and it costs a hash build
-- over 131 rows, which is inside the 1.09 s above.
voteBaseFrom :: VoteJoins -> Text
voteBaseFrom j =
  " FROM public.voting_procedure v \
  \ JOIN palmares.gov_action w ON w.gov_action_id = v.gov_action_proposal_id "
    <> onlyIf (vjBlock j) " JOIN public.tx t ON t.id = v.tx_id JOIN public.block b ON b.id = t.block_id "
    <> onlyIf (vjAnchor j) " LEFT JOIN palmares.anchor a ON a.voting_anchor_id = v.voting_anchor_id "
    <> onlyIf (vjDRep j) " LEFT JOIN palmares.drep d ON d.drep_hash_id = v.drep_voter "
    <> onlyIf
      (vjCold j)
      " LEFT JOIN palmares.cc_cold_interval cold \
      \   ON cold.hot_key_id = v.committee_voter AND cold.from_tx <= v.tx_id \
      \  AND (cold.to_tx IS NULL OR cold.to_tx > v.tx_id) "
    <> onlyIf
      (vjPower j)
      " LEFT JOIN palmares.drep_epoch_power p \
      \   ON p.target_kind = 'drep' AND p.drep_hash_id = v.drep_voter \
      \  AND p.epoch_no = w.last_votable_epoch "
  where
    onlyIf c s = if c then s else ""

-- | The @WHERE@ over base columns.
--
-- __The voter filter needs no cold-key join.__ It is expressed as membership in the tiny hash
-- tables — 805 @drep_hash@ rows, 686 @pool_hash@, 48 @committee_hash@ — plus, for the committee,
-- the hot keys ever registered to that cold credential. Each subquery has no outer reference, so
-- PostgreSQL evaluates it once as an InitPlan and the qual becomes a cheap per-row test. MEASURED:
-- resolving one cold id to its hot keys is 11 ms, against the 9.5 s the interval join costs.
--
-- That is also WHY the committee arm is two clauses: a committee vote is signed by a HOT key and
-- published under the COLD one (D-24), so a cold id must match both the cold credential's own row
-- (for a member who never rotated) and every hot key registered to it.
voteBaseWhere :: VoteFilter -> (Text, [PersistValue])
voteBaseWhere f =
  let clauses =
        concat
          [ inClause "v.voter_role::text" (map pascalRole (voteFilterRoles f)),
            voterClause (voteFilterVoterIds f),
            inClause "encode(w.tx_hash, 'hex') || '#' || w.index" (map unGovActionId (voteFilterGovActionIds f)),
            inClause "v.vote::text" (map pascalVerdict (voteFilterVerdicts f)),
            inClause "w.action_type::text" (map (T.pack . show) (voteFilterGovActionTypes f)),
            inClause "a.verdict" (map jsonTag (voteFilterAnchorStatus f)),
            one "b.time >= ?" (voteFilterFrom f),
            one "b.time <= ?" (voteFilterTo f),
            one "b.epoch_no >= ?" (voteFilterFromEpoch f),
            one "b.epoch_no <= ?" (voteFilterToEpoch f),
            qClause (voteFilterQ f)
          ]
   in ( if null clauses then "" else " WHERE " <> T.intercalate " AND " (map fst clauses),
        concatMap snd clauses
      )
  where
    one sql = maybe [] (\v -> [(sql, [toPersistValue v])])

    inClause col vs
      | null vs = []
      | otherwise =
          [(col <> " IN (" <> placeholders vs <> ")", map toPersistValue vs)]

    voterClause vs
      | null vs = []
      | otherwise =
          [ ( "( v.drep_voter IN (SELECT dh.id FROM public.drep_hash dh WHERE dh.raw IN ("
                <> decoders
                <> ")) \
                   \ OR v.pool_voter IN (SELECT ph.id FROM public.pool_hash ph WHERE ph.hash_raw IN ("
                <> decoders
                <> ")) \
                   \ OR v.committee_voter IN (SELECT ch.id FROM public.committee_hash ch WHERE ch.raw IN ("
                <> decoders
                <> ")) \
                   \ OR v.committee_voter IN (SELECT cr.hot_key_id FROM public.committee_registration cr \
                   \                          JOIN public.committee_hash ch2 ON ch2.id = cr.cold_key_id \
                   \                          WHERE ch2.raw IN ("
                <> decoders
                <> ")) )",
              concat (replicate 4 (map toPersistValue vs))
            )
          ]
      where
        decoders = T.intercalate ", " (map (const "decode(?, 'hex')") vs)

    qClause = maybe [] $ \raw ->
      let p = likePat raw
       in [ ( "(lower(w.title) LIKE ? OR lower(w.abstract) LIKE ? OR lower(d.given_name) LIKE ?)",
              [toPersistValue p, toPersistValue p, toPersistValue p]
            )
          ]

    placeholders vs = T.intercalate ", " (map (const "?") vs)

    pascalRole r = case r of
      DRep -> "DRep" :: Text
      SPO -> "SPO"
      ConstitutionalCommittee -> "ConstitutionalCommittee"

    pascalVerdict v = case v of
      Yes -> "Yes" :: Text
      No -> "No"
      Abstain -> "Abstain"

-- | The sort, over base columns.
--
-- __@cast_at@ orders by @voting_procedure.id@__, not by a block time, and the two are the same
-- order: db-sync assigns ids in chain order, so @id DESC@ is @block.time DESC@ refined within a
-- block — which is exactly what the published tie-break @(cast_at DESC, voting_procedure_id DESC)@
-- already said. VERIFIED rather than assumed: the top 50 by @id DESC@ and the top 50 by
-- @(b.time DESC, v.id DESC)@ are the same 50 rows, 0 disagreements. It is worth the check because
-- it removes the @tx ⋈ block@ join from the default sort, and that join is 8.7 s of a 9.9 s page.
voteBaseSortSpec :: VotesOrderBy -> SortSpec
voteBaseSortSpec = \case
  VotesOrderByCastAt -> SortSpec "v.id" False tie
  VotesOrderByVotingPower -> SortSpec "p.amount" True tie
  VotesOrderByLatency -> SortSpec "(b.time - w.proposed_at)" True tie
  VotesOrderByVoterId -> SortSpec "COALESCE(cold.cold_raw, dh2.raw, ph2.hash_raw, ch3.raw)" False tie
  VotesOrderByGovActionId -> SortSpec "v.gov_action_proposal_id" False tie
  where
    tie = "v.id"

-- | The extra joins the @voter_id@ sort needs to order by the PUBLISHED identity.
--
-- Only for that one sort, which is why they are not in 'voteBaseFrom': ordering by an opaque
-- credential is a rare request, and making every other page pay four joins for it would be the
-- shape this rewrite exists to remove.
voteIdentityJoins :: Text
voteIdentityJoins =
  " LEFT JOIN public.drep_hash dh2 ON dh2.id = v.drep_voter \
  \ LEFT JOIN public.pool_hash ph2 ON ph2.id = v.pool_voter \
  \ LEFT JOIN public.committee_hash ch3 ON ch3.id = v.committee_voter "
