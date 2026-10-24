{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Health and readiness probe API for the chain-sync service.
-- Exposes sync metrics so orchestrators can determine whether the
-- service is caught up with the blockchain tip.
module ChainsyncAPI where

import Palmares.Constants (appVersion)
import Control.Concurrent.MVar (MVar, readMVar)
import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Swagger (ToSchema)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Database.Persist.Sql (ConnectionPool, Single (..), SqlPersistT, rawSql)
import Deriving.Aeson
import Palmares.Storage (currentSchemaVersion, runAttest)
import Servant
import Palmares.WebAPI.CORS qualified as WebAPI.CORS
import Palmares.WebAPI.Envelope (ErrorCode (..), errorCodeToHttpStatus)
import Palmares.WebAPI.Errors (mkServantErr)
import Palmares.WebAPI.ServiceProbe
import System.Timeout (timeout)

data ChainSyncState = UpToDate | UpToDateButDifferentBlockHash | Behind {isWayBehind :: Bool}| Ahead
  deriving (Show, Eq, Generic, ToJSON, FromJSON, ToSchema)

-- | Snapshot of chain-sync progress, returned by health/readiness probes.
data SyncMetrics = SyncMetrics
  { smLocalTip :: Integer, -- ^ Slot number of the last processed checkpoint
    smBlockchainTip :: Integer, -- ^ Slot number of the latest known blockchain tip
    -- | Wall-clock time of the last successful read from Kupo — the moment the projector last had
    -- EVIDENCE about the chain, written on every tick and again after every applied fetch window.
    -- It is what 'readyVerdict' measures the tick's age against; see that function for why a
    -- frozen value here is the only available signal that Kupo has gone away.
    smLastSyncTime :: UTCTime,
    -- | Whether the projection database answered THIS request. Measured per probe by
    -- 'probeDatabase'; the value carried in the shared 'MVar' is a placeholder that is overwritten
    -- before either endpoint serves it, and is never read.
    smDbReady :: Bool,
    -- | Whether the schema in that database is the one this binary migrates to. Measured per probe,
    -- same placeholder rule as 'smDbReady'.
    smMigrationsComplete :: Bool,
    smChainSyncState :: ChainSyncState -- ^ Derived sync state (UpToDate, Behind, etc.)
  }
  deriving (Generic, ToSchema, Show)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "sm", CamelToSnake]] SyncMetrics

-- | How long a probe waits for the database before calling it unreachable.
--
-- Two seconds, because a probe is hit every few seconds and the query behind it is one bounded read
-- of a one-row table — measured at 0.014 ms on the live preprod database. The bound exists for the
-- failure that is NOT an exception: a host that drops packets rather than refusing the connection
-- leaves @connect(2)@ waiting for the OS timeout, around 75 seconds, and an unbounded probe would
-- hang instead of reporting. GHC's 'timeout' cannot interrupt the blocking libpq call itself, so
-- this bounds the ANSWER and not the connection — which is the half a probe needs.
probeTimeoutMicros :: Int
probeTimeoutMicros = 2_000_000

-- | @(db_ready, migrations_complete)@, measured now rather than remembered from boot.
--
-- __The failure this exists for.__ Both booleans used to be @True@ literals set in @main@ before the
-- loop started, so the probe went on reporting a healthy database after the database had gone away.
-- That is not hypothetical here: the postmaster restarted, db-sync restarted, this service died with
-- exit 1 and no reconnect — and until the process actually exited its own probe reported perfect
-- health, because the two fields had been decided at boot and nothing ever revisited them.
--
-- __One query, and what each answer means.__ @SELECT schema_version FROM chain_sync_config LIMIT 1@,
-- through 'runAttest' so it resolves in @palmares_attest@ like every other access in this service.
-- It is a single-row read off a singleton table, deliberately NOT a schema inspection: measured on
-- the live preprod database, this plan is @Limit -> Seq Scan@ over one row, 0.014 ms and one shared
-- buffer hit, against 1.155 ms and 178 buffer hits for a single @information_schema.tables@
-- existence check — and 'Palmares.Storage.readSchemaProbe', the boot-time probe, does two of those
-- plus the row read. At a probe every few seconds the difference is the whole reason this is a
-- second query rather than a call to that one.
--
--   * it answered with the row, and the version is this binary's → @(True, True)@;
--   * it answered with the row, and the version is NOT this binary's → @(True, False)@. This is the
--     case a boot-time literal can never produce and the one the incident above would have shown:
--     a database restored from an older dump under a running projector holds a schema this binary
--     does not migrate to, so its writes would be wrong rather than merely late;
--   * it answered with no row → @(True, False)@: the database is up and the migration never
--     finished;
--   * it raised, or did not answer within 'probeTimeoutMicros' → @(False, False)@.
--
-- The last line also swallows one distinction, deliberately: a missing @chain_sync_config@ raises
-- @relation does not exist@, so an up-but-unmigrated database reads as unreachable rather than as
-- unmigrated. Separating the two would cost a second round trip to learn something that changes
-- neither the verdict (503 either way) nor the remedy (look at the projector's boot log), and one
-- query is the budget a probe on this path gets.
probeDatabase :: ConnectionPool -> IO (Bool, Bool)
probeDatabase pool = do
  r <- timeout probeTimeoutMicros (try @SomeException (runAttest pool storedSchemaVersion))
  pure $ case r of
    Just (Right [Single v]) -> (True, v == currentSchemaVersion)
    Just (Right _) -> (True, False)
    _ -> (False, False)
  where
    storedSchemaVersion :: SqlPersistT IO [Single Int]
    storedSchemaVersion = rawSql "SELECT schema_version FROM chain_sync_config LIMIT 1" []

-- | @Nothing@ means ready. Otherwise the code to serve with 503.
--
-- Pure, and separate from the handler, for the reason query-api's @readyVerdict@ is: the verdict is
-- the part worth pinning by a test, and the handler around it is plumbing. Three dependencies, and
-- each of them is a way this service can be running perfectly and still unable to answer honestly:
--
--   * __PostgreSQL__ — 'probeDatabase' asked it, this request, and it did not answer.
--   * __the schema__ — it answered, with a version this binary does not write.
--   * __Kupo__, through the age of the tick. This is the signal that was missing entirely, and the
--     one a slot comparison cannot give: 'getBlockchainTip' retries inside the tick, so with Kupo
--     unreachable nothing below it runs — the metrics 'MVar' is never touched and
--     @chain_sync_state@, @local_tip@ and @blockchain_tip@ all freeze at their last good values.
--     @\/ready@ answered 200 off those frozen numbers indefinitely. A tick that has not completed
--     is therefore the only evidence available, and it is sufficient: the loop sleeps ten seconds
--     when up to date and ten more between Kupo retries, so an age in the hundreds of seconds means
--     tens of missed ticks.
--   * __the cursor's freshness__ — the slot gap, via @smChainSyncState@, which @main@ computes with
--     this same configured threshold so the @is_way_behind@ a client reads and the verdict it gets
--     cannot disagree.
--
-- __The tick age is compared against the SLOT threshold__, which is one knob doing two jobs rather
-- than a second magic number: at one second per slot, a projector that has had no word from Kupo
-- for @n@ seconds is by definition at least @n@ slots stale, so the operator's tolerance for
-- staleness is the same number whichever way the staleness is measured.
--
-- That reuse is also this check's CEILING, and it is worth naming: at the default threshold a dead
-- Kupo takes 1200 seconds to turn @\/ready@ red, because 1200 is what the operator said staleness
-- may reach. An operator who wants it sooner lowers @READY_MAX_LAG_SLOTS@, which tightens both
-- halves together. If the two ever need to diverge, the upgrade is a second variable and a second
-- argument here — not a hardcoded multiple of the loop's sleep, which is what this replaced.
--
-- @Behind False@ stays green on purpose: a healthy projector is a slot or two behind the tip
-- between blocks, and a probe that went red there would take a correct service out of rotation
-- every twenty seconds.
readyVerdict :: Integer -> Integer -> SyncMetrics -> Maybe ErrorCode
readyVerdict maxLagSlots tickAgeSeconds m
  | not (smDbReady m) = Just DbUnavailable
  | not (smMigrationsComplete m) = Just NotReady
  | tickAgeSeconds > maxLagSlots = Just IndexerBehind
  | otherwise = case smChainSyncState m of
      UpToDate -> Nothing
      Behind False -> Nothing
      Behind True -> Just IndexerBehind
      -- Kupo is serving a chain whose tip is BELOW our cursor, so the index this service reads is
      -- the thing that is behind. The next tick rolls back; until it has, the projections above
      -- Kupo's tip are not answerable.
      Ahead -> Just IndexerBehind
      -- Same slot, different block: our cursor names a block that is not on the chain. The service
      -- is fine and its data is on a fork, which is 'NotReady' rather than a lag.
      UpToDateButDifferentBlockHash -> Just NotReady

type ServiceProbeAPI = ServiceProbe SyncMetrics SyncMetrics

proxyServiceProbeAPI :: Proxy ServiceProbeAPI
proxyServiceProbeAPI = Proxy

-- | Servant server for the health and readiness endpoints.
--
-- The pool is here because the two dependency booleans are measured per request rather than
-- remembered from boot — see 'probeDatabase'. The threshold is here because @\/ready@ compares the
-- tick's age against it; @main@ reads it once from @READY_MAX_LAG_SLOTS@ and passes the same value
-- to 'ChainSyncLogic.evaluateChainSyncStateWith', so both halves of the verdict use one number.
--
-- __@\/health@ measures the database too__, which departs from query-api's rule that a liveness
-- probe touches nothing. It has to: this service's @\/health@ PUBLISHES @db_ready@ and
-- @migrations_complete@ as data, so either it measures them or it must not publish them, and a
-- liveness probe that reports a database it has not asked is the defect this change exists to fix.
-- The cost is bounded at 'probeTimeoutMicros' and the check cannot throw, so a dead database makes
-- @\/health@ answer @db_ready: false@ rather than fail — a restart is this service's only recovery
-- from a lost connection anyway, since it has no reconnect path of its own.
serviceProbeServer :: ConnectionPool -> Integer -> MVar SyncMetrics -> ServerT ServiceProbeAPI Handler
serviceProbeServer pool maxLagSlots metricsVar = handleHealth' :<|> handleReady'
  where
    mkProbe m = do
      (dbOk, migrationsOk) <- liftIO (probeDatabase pool)
      now <- liftIO getCurrentTime
      let ts = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now
          measured = m {smDbReady = dbOk, smMigrationsComplete = migrationsOk}
      return ServiceProbeStatus {status = measured, service = "chain-sync", version = T.pack appVersion, timestamp = ts}

    handleHealth' = do
      m <- liftIO $ readMVar metricsVar
      mkProbe m

    -- The refusal carries the documented @{code, message}@ body, like every other refusal in this
    -- project, and `mkServantErr` puts `application/json` on it. It used to be
    -- `err503 {errBody = BL8.pack (show probeStatus)}`: a Haskell-rendered record — `status =
    -- SyncMetrics {smLocalTip = …, smChainSyncState = Behind {isWayBehind = True}}` — under
    -- servant's bare `err503`, whose `errHeaders` are empty, so the response carried no content type
    -- either. A client that could parse the 200 could not parse the 503, and there was no `code` to
    -- branch on: the three reasons a projector refuses were one indistinguishable blob.
    handleReady' = do
      m <- liftIO $ readMVar metricsVar
      probeStatus <- mkProbe m
      now <- liftIO getCurrentTime
      let measured = status probeStatus
          tickAgeSeconds = floor (diffUTCTime now (smLastSyncTime measured)) :: Integer
      case readyVerdict maxLagSlots tickAgeSeconds measured of
        Nothing -> pure probeStatus
        Just code -> throwError (mkServantErr (errorCodeToHttpStatus code) code)

-- | Build a WAI 'Application' that serves the chain-sync probe endpoints with CORS.
mkServiceProbeApp :: WebAPI.CORS.CorsConfig -> ConnectionPool -> Integer -> MVar SyncMetrics -> Application
mkServiceProbeApp corsCfg pool maxLagSlots metricsVar =
  WebAPI.CORS.mkCorsMiddleware corsCfg $
    serve proxyServiceProbeAPI (serviceProbeServer pool maxLagSlots metricsVar)
