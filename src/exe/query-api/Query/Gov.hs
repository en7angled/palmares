{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE ImportQualifiedPost #-}
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
  )
import Deriving.Aeson
import Network.HTTP.Types.Header (Header)
import Network.Wai (Middleware, mapResponseHeaders)
import Palmares.DomainTypes.Transfer.QueryResponses (EpochParamsSummary (..), SyncStatus (..))
import Palmares.WebAPI.Envelope (ErrorCode (..))
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
