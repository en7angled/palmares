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

    -- * DReps
    drepSortSpec,
    drepWhere,
    listDReps,

    -- * The DRep profile
    resolveDRepHex,
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
    listVotes,
  )
where

import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Data.Aeson (FromJSON, eitherDecodeStrict)
import Data.ByteString.Char8 qualified as BS8
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
    rawSql,
    runSqlPoolWithIsolation,
    toPersistValue,
  )
import Deriving.Aeson
import Network.HTTP.Types.Header (Header)
import Network.Wai (Middleware, mapResponseHeaders)
import Palmares.DomainTypes.Core.Types
  ( AnchorStatus,
    DRepStatus (..),
    GovActionId (..),
    Vote (..),
    VoterRole (..),
  )
import Palmares.DomainTypes.Transfer.Filters (DRepFilter (..), GovActionFilter (..), VoteFilter (..))
import Palmares.DomainTypes.Transfer.OrderBy
  ( DRepsOrderBy (..),
    DelegatorsOrderBy (..),
    GovActionsOrderBy (..),
    SortOrder (..),
    VotesOrderBy (..),
  )
import Data.Int (Int64)
import Palmares.DomainTypes.Transfer.QueryResponses
  ( AnchorContent,
    DRepMetrics,
    DRepSummary,
    DRepUpdateRow,
    DelegatorRow,
    DelegatorStats,
    EpochParamsSummary (..),
    EpochPowerPoint,
    GovActionAnchorContent,
    GovActionSummary,
    ProposerSummary,
    SyncStatus (..),
    TreasuryWithdrawalRow,
    VoteRecord,
    VoteTally,
  )
import Palmares.Metrics.Catalog (lookupMetricSql)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.Envelope (ErrorCode (..), Page (..))
import Query.Common (Limit, Offset, SortSpec (..), likePat, orderClause)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Run a governance read in one @RepeatableRead@ transaction. See rule 1 in the module header.
runGovRead :: ConnectionPool -> SqlPersistT IO a -> IO a
runGovRead pool act = runSqlPoolWithIsolation act pool RepeatableRead

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
    readyExpectedNetwork :: Text
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
--     answer every question confidently with another chain's data.
readyVerdict :: Int -> ReadyInputs -> Maybe ErrorCode
readyVerdict maxLag ReadyInputs {..}
  | not readyDbOk = Just DbUnavailable
  | readyLagSeconds > maxLag = Just IndexerBehind
  | readyDrepDistrEpoch < readyEpochNo - 1 = Just IndexerBehind
  | readyNetworkName /= readyExpectedNetwork = Just NotReady
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
startFreshnessPoll :: ConnectionPool -> Int -> IO (TVar (Maybe Freshness), ThreadId)
startFreshnessPoll pool pollMs = do
  tv <- newTVarIO Nothing
  poll tv
  tid <- forkIO . forever $ do
    threadDelay (pollMs * 1000)
    poll tv
  pure (tv, tid)
  where
    poll tv = do
      r <- try (runGovRead pool freshnessQuery)
      case r of
        Right (Just f) -> atomically (writeTVar tv (Just f))
        Right Nothing ->
          hPutStrLn stderr "[freshness] palmares.sync_state is empty: db-sync has no blocks yet"
        Left (e :: SomeException) ->
          hPutStrLn stderr ("[freshness] poll failed, keeping the previous value: " <> show e)

-- | Stamp every response with the chain point its data came from.
--
-- Five headers rather than a field in each body, because the question \"how fresh is this\"
-- applies to every response including the ones that are an error body, and because a client can
-- then show a staleness chip without parsing anything. They are added on the way out, so a
-- handler cannot forget them.
freshnessMiddleware :: IO (Maybe Freshness) -> Middleware
freshnessMiddleware readFresh app req respond = do
  mf <- readFresh
  app req (respond . mapResponseHeaders (<> maybe [] freshnessHeaders mf))

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

    -- The default. See DRepFilter's haddock for why it is not "every credential".
    effectiveStatus
      | null (drepFilterStatus f) = [DRepActive, DRepInactive]
      | otherwise = drepFilterStatus f

    -- status is not a column: it is `registration_status` and `is_active` composed, and the
    -- composition lives HERE in one expression rather than in both the projection and the filter,
    -- so a page cannot show a status the filter would have excluded.
    statusExpr =
      "(CASE WHEN d.registration_status = 'retired' THEN 'retired' \
      \      WHEN d.is_active THEN 'active' ELSE 'inactive' END)"

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
  \ d.has_script, \
  \ (CASE WHEN d.registration_status = 'retired' THEN 'retired' \
  \       WHEN d.is_active THEN 'active' ELSE 'inactive' END) AS status, \
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
    \    WHERE v.drep_voter_id = (SELECT drep_hash_id FROM m) AND v.seq_last = 1 \
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
listEpochPower :: Int64 -> Maybe Int -> Maybe Int -> SortOrder -> Limit -> SqlPersistT IO [EpochPowerPoint]
listEpochPower dhid fromEpoch toEpoch so lim =
  queryJson
    ( "SELECT row_to_json(x)::text FROM ( \
      \  SELECT p.epoch_no AS epoch, p.amount AS lovelace, dd.delegator_count \
      \  FROM palmares.drep_epoch_power p \
      \  LEFT JOIN palmares.drep_epoch_delegators dd \
      \    ON dd.drep_hash_id = p.drep_hash_id AND dd.epoch_no = p.epoch_no \
      \  WHERE p.drep_hash_id = ? AND p.target_kind = 'drep' "
        <> maybe "" (const " AND p.epoch_no >= ? ") fromEpoch
        <> maybe "" (const " AND p.epoch_no <= ? ") toEpoch
        <> " ORDER BY p.epoch_no "
        <> (case so of Asc -> "ASC"; Desc -> "DESC")
        <> " LIMIT ? ) x"
    )
    ( [toPersistValue dhid]
        <> maybe [] (\e -> [toPersistValue e]) fromEpoch
        <> maybe [] (\e -> [toPersistValue e]) toEpoch
        <> [toPersistValue lim]
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

-- | One page of votes, with a total over the same predicate.
listVotes :: VoteFilter -> (VotesOrderBy, SortOrder) -> (Limit, Offset) -> SqlPersistT IO (Page VoteRecord)
listVotes f (ob, so) (lim, off) = do
  items <-
    queryJson
      ( "SELECT row_to_json(x)::text FROM ( SELECT "
          <> voteProjection
          <> voteFrom
          <> whereSql
          <> " "
          <> orderClause (voteSortSpec ob) so
          <> " LIMIT ? OFFSET ? ) x"
      )
      (params <> [toPersistValue lim, toPersistValue off])
  totals <- rawSql ("SELECT count(*)::int" <> voteFrom <> whereSql) params
  pure (Page items (Just (case totals of (Single n : _) -> n; [] -> 0)) lim off Nothing)
  where
    (whereSql, params) = voteWhere f

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
