{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | The three endpoints that answer \"can this service be trusted right now\".
--
-- They are three questions, not one, and conflating them is how a registry ends up serving stale
-- data confidently:
--
--   * @\/health@ — is the process alive. Touches nothing, so a slow database cannot get the pod
--     restarted.
--   * @\/ready@ — should it receive traffic. Four checks, any of which makes an answer
--     misleading rather than wrong.
--   * @\/status@ — the numbers behind that verdict, plus the protocol parameters a client needs
--     to audit any tally we publish.
module Query.ServiceStatus
  ( getHealthProbe,
    getReadyProbe,
    getStatusQuery,
  )
where

import Control.Concurrent.STM (readTVarIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text, pack)
import Palmares.Constants (appVersion)
import Palmares.DomainTypes.Transfer.QueryResponses (StatusResponse (..))
import Palmares.WebAPI.Envelope (ErrorCode (..))
import Palmares.WebAPI.ServiceProbe (ServiceProbeStatus, alwaysHealthy, mkProbeStatus)
import Query.Gov
  ( Freshness (..),
    ReadyInputs (..),
    epochParamsQuery,
    readyVerdict,
    syncStatusOf,
  )
import QueryAppMonad (QueryAppContext (..), QueryAppMonad, runRead, throwApi)

-- | Liveness. Deliberately stateless.
getHealthProbe :: QueryAppMonad (ServiceProbeStatus Text)
getHealthProbe = alwaysHealthy (pack appVersion) "query-api"

-- | Readiness, from the cached freshness. 503 with the failing code, or @ready@.
--
-- An empty cache is 'DbUnavailable' rather than a 200: the poll is seeded synchronously at boot,
-- so an empty cache means every poll since has failed.
getReadyProbe :: QueryAppMonad (ServiceProbeStatus Text)
getReadyProbe = do
  (maxLag, inputs) <- readyInputs
  case readyVerdict maxLag inputs of
    Just code -> throwApi code
    Nothing -> mkProbeStatus "ready" (pack appVersion) "query-api"

-- | @GET \/status@: the freshness numbers and the protocol parameters they mean something against.
--
-- @is_ready@ is the same verdict @\/ready@ gives, computed from the same inputs, so a client sees
-- one answer rather than two that can disagree.
getStatusQuery :: QueryAppMonad StatusResponse
getStatusQuery = do
  mf <- currentFreshness
  case mf of
    Nothing -> throwApi DbUnavailable
    Just f -> do
      (maxLag, inputs) <- readyInputs
      mParams <- runRead epochParamsQuery
      case mParams of
        -- No epoch_param row at all means db-sync has not reached Shelley, or is running without
        -- the ledger state that writes it. Either way no tally we publish could be audited, which
        -- is a readiness condition rather than an empty field.
        Nothing -> throwApi IndexerBehind
        Just params -> do
          net <- asks expectedNetwork
          pure
            StatusResponse
              { statusNetwork = net,
                statusGovernance = syncStatusOf f (readyVerdict maxLag inputs == Nothing),
                -- The same 'ReadyInputs' the verdict above is computed from, so a @503
                -- IndexerBehind@ and the number a reader diagnoses it with cannot come from two
                -- different polls. Published AS MEASURED — the projector's distance from db-sync's
                -- cursor — while 'readyVerdict' tests that plus @governance.lag_seconds@, because
                -- the ceiling bounds absolute staleness. So this field is an INPUT to the verdict
                -- and not the quantity compared against the ceiling; both numbers are on this
                -- response, and their sum is what the probe judged.
                statusAttestLagSeconds = readyAttestLagSeconds inputs,
                statusEpochParams = params
              }

currentFreshness :: QueryAppMonad (Maybe Freshness)
currentFreshness = asks freshness >>= liftIO . readTVarIO

-- | Gather the configured lag ceiling and the four readiness inputs.
--
-- A missing @drep_distr_epoch@ or @network_name@ counts as failing rather than as unknown: both
-- are subqueries in @palmares.sync_state@ that go NULL when the table behind them is empty, which
-- is exactly the \"db-sync is not ready\" condition the probe exists to report. @-1@ and @\"\"@
-- are chosen so each falls on the failing side of its own check rather than needing a fifth one.
readyInputs :: QueryAppMonad (Int, ReadyInputs)
readyInputs = do
  mf <- currentFreshness
  attest <- asks attestLag >>= liftIO . readTVarIO
  net <- asks expectedNetwork
  maxLag <- asks readyMaxLag
  pure . (maxLag,) $ case mf of
    Nothing ->
      ReadyInputs
        { readyDbOk = False,
          readyLagSeconds = 0,
          readyEpochNo = 0,
          readyDrepDistrEpoch = 0,
          readyNetworkName = "",
          readyExpectedNetwork = net,
          -- No database reading at all, so no evidence about the projector either. `readyDbOk`
          -- already fails this case; claiming a projector lag here would be inventing one.
          readyAttestLagSeconds = Nothing
        }
    Just f ->
      ReadyInputs
        { readyDbOk = True,
          readyLagSeconds = freshLagSeconds f,
          readyEpochNo = freshEpoch f,
          readyDrepDistrEpoch = maybe (-1) id (freshDrepDistrEpoch f),
          readyNetworkName = maybe "" id (freshNetworkName f),
          readyExpectedNetwork = net,
          readyAttestLagSeconds = attest
        }
