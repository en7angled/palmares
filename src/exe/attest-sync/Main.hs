{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Main where

import ChainSyncLogic
import ChainSyncServer (startProbeServer)
import ChainsyncAPI (ChainSyncState (..), SyncMetrics (..))
import Palmares.Constants
import Control.Concurrent.Extra
import Control.Monad.Extra
import Control.Monad.IO.Class
import Control.Monad.Logger (runStdoutLoggingT)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
import Database.Persist.Postgresql (ConnectionString, createPostgresqlPool)
import Database.Persist.Sql (runSqlPool)
import GeniusYield.GYConfig (GYCoreConfig (..))
import GeniusYield.Types (mintingPolicyIdFromText)
import Palmares.ChainSync.KupoClient (KupoCheckpoint (..))
import Palmares.Storage
  ( currentSchemaVersion,
    ensureAttestSchema,
    putStoredPolicyHistory,
    parsePolicyHistory,
    readSchemaProbe,
    rollbackTo,
    runAttest,
    runMigrations,
    wipeChainSyncTablesRaw,
  )
import System.Environment (lookupEnv)
import System.Exit (die)
import Text.Printf
import Text.Read (readMaybe)
import Palmares.TxBuilding.Context
import Palmares.Utils (decodeConfigEnvOrFile)
import Palmares.WebAPI.CORS (getCorsConfigFromEnv)
import Palmares.WebAPI.Utils
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

defaultKupoUrl :: String
defaultKupoUrl = "http://localhost:1442"

-- | Show only the host and dbname fields of a Postgres DSN, hiding the password.
redactConnStr :: String -> String
redactConnStr s =
  unwords [kv | kv <- words s, let k = takeWhile (/= '=') kv, k `elem` ["host", "dbname", "port"]]

main :: IO ()
main = do
  -- Line-buffer stdout: GHC block-buffers it when it is not a TTY, which is the case under
  -- Docker and Kubernetes, so boot lines would sit in a buffer while the service already serves.
  -- Measured on query-api, fixed in all three servers at once.
  hSetBuffering stdout LineBuffering

  port <- getPortFromEnvOrDefault 8084
  corsCfg <- getCorsConfigFromEnv

  kupoUrl <- liftIO $ fmap (fromMaybe defaultKupoUrl) (lookupEnv "KUPO_URL")
  connStr <- liftIO requirePgConnStr

  let connBS :: ConnectionString = TE.encodeUtf8 (T.pack connStr)
  pool <- runStdoutLoggingT $ createPostgresqlPool connBS 16

  atlasConfig <- maybe (die "Atlas configuration failed") return =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" defaultAtlasCoreConfig
  let networkId = cfgNetworkId atlasConfig

  deployedScriptsContext <- maybe (die "Deployed validators configuration failed") return =<< decodeConfigEnvOrFile @DeployedScriptsContext "DEPLOYED_VALIDATORS_CONFIG" defaultTxBuildingContextFile
  let policyHexText = T.pack $ printf "%s" (getMintingPolicyHash deployedScriptsContext)

  -- The same hash, typed, because the projection path needs it to authenticate every output it
  -- indexes (inherited fix #3) and the Kupo pattern needs it as text. Parsed once, here, so a
  -- deployed-config hash that is not a policy id is a boot failure and not a per-match surprise.
  ourPolicy <-
    either
      (\e -> die ("Deployed minting policy hash is not a policy id: " <> e))
      return
      (mintingPolicyIdFromText policyHexText)

  -- Probe the existing schema BEFORE migrating. Wipe (drop) the chain-sync tables if the schema
  -- version or minting policy changed, so migrateAll only CREATEs fresh tables and never runs an
  -- incompatible in-place ALTER (varchar->bigint / ADD COLUMN NOT NULL) that Postgres would reject.
  -- The schema first, and the path pinned to it for everything after: these tables are declared
  -- unqualified, so without this they land in `palmares`, which query-api drops on every boot.
  runSqlPool ensureAttestSchema pool
  mProbe <- runAttest pool readSchemaProbe

  -- A POLICY CHANGE NO LONGER WIPES — ADR 0007, stance (a) of `OC-09`.
  --
  -- It used to: `storedPolicy /= policyHexText` dropped every chain-sync table, so a redeploy
  -- destroyed the previous registry's records. That is precisely what the stance promises not to do
  -- — "a redeploy is a new registry and the old records remain readable" — and the promise would
  -- have been false in the one place that could falsify it.
  --
  -- Nothing has to be migrated for the old rows to stay readable: every id is stored as a
  -- `GYAssetClass`, which is @policy.name@, so each row already says which registry it belongs to
  -- and a reader unions deployments for free. What changes is only that the table keeps them.
  --
  -- A SCHEMA VERSION BUMP STILL WIPES, and that is a different question: those tables would need an
  -- in-place ALTER that Postgres rejects (varchar->bigint, ADD COLUMN NOT NULL), so a fresh CREATE
  -- is the only safe path and the records are re-indexed from the chain afterwards.
  let needWipe = case mProbe of
        Nothing -> False
        Just (storedVersion, _storedPolicies) -> storedVersion < currentSchemaVersion
  when needWipe $ do
    putStrLn "Schema version changed; dropping chain-sync tables before migration."
    runAttest pool wipeChainSyncTablesRaw
  runAttest pool runMigrations

  -- The history this database holds, newest first. The current policy goes to the head unless it is
  -- already there, so a restart is idempotent and a redeploy appends.
  let previousPolicies = if needWipe then [] else maybe [] (parsePolicyHistory . snd) mProbe
      policyHistory = policyHexText : filter (/= policyHexText) previousPolicies
  runAttest pool (putStoredPolicyHistory policyHistory)
  case filter (/= policyHexText) previousPolicies of
    [] -> return ()
    older ->
      putStrLn
        ( "Policy history: indexing "
            <> T.unpack policyHexText
            <> " and KEEPING the records of "
            <> show (length older)
            <> " earlier registry/registries ("
            <> T.unpack (T.intercalate ", " older)
            <> "). Their records stay readable and stop being updated: a redeploy is a new registry."
        )

  fetchBatchSize <- do
    mb <- lookupEnv "FETCH_BATCH_SIZE"
    pure $ max 1 (maybe (10_000_000 :: Integer) id (mb >>= readMaybe))

  rollbackMargin <- do
    mb <- lookupEnv "ROLLBACK_MARGIN"
    pure $ max 1 (maybe defaultRollbackMargin id (mb >>= readMaybe))

  initialTip <- getLocalTip pool

  now <- getCurrentTime
  metricsVar <-
    newMVar
      SyncMetrics
        { smLocalTip = ck_slot_no initialTip,
          smBlockchainTip = ck_slot_no initialTip,
          smLastSyncTime = now,
          smDbReady = True,
          smMigrationsComplete = True,
          smChainSyncState = Behind True -- by default we are way behind
        }

  -- Start probe server
  void $ forkIO $ startProbeServer corsCfg port metricsVar

  let matchPattern = policyHexText <> ".*"
  putStrLn "Starting chain-sync ..."
  putStrLn "Kupo: configured"
  putStrLn ("Pattern: " <> T.unpack matchPattern)
  putStrLn ("Postgres: " <> redactConnStr connStr)

  forever $ do
    blockchainTip <- getBlockchainTip kupoUrl
    localTip <- getLocalTip pool
    let chainSyncState = evaluateChainSyncState localTip blockchainTip
    modifyMVar_ metricsVar $ \m -> pure m {smLocalTip = ck_slot_no localTip, smBlockchainTip = ck_slot_no blockchainTip, smChainSyncState = chainSyncState}
    liftIO $ putStrLn ("Local tip      : " <> show (ck_slot_no localTip))
    liftIO $ putStrLn ("Blockchain tip : " <> show (ck_slot_no blockchainTip))

    -- CS-02: ask whether our cursor's own block is still on the chain, BEFORE trusting the
    -- slot comparison. A short fork reads as plain `Behind` — local slot below the tip — and that
    -- path never looks at a header, so the orphaned block's projections stayed and a replacement
    -- block below our cursor was never fetched again.
    cursor <- verifyCursor kupoUrl localTip
    case cursor of
      CursorOrphaned ancestor -> do
        -- Kupo's ancestor is a point on the chain it is serving now, so it is a PRECISE target.
        -- The margin stays as the fallback for the case where Kupo knows nothing at or below our
        -- slot, which is the shape the old code always assumed.
        let target = maybe (max 0 (ck_slot_no blockchainTip - rollbackMargin)) ck_slot_no ancestor
        liftIO $
          putStrLn
            ( "FORK: the cursor's block is not on Kupo's chain; rolling back to "
                <> show target
                <> maybe " (margin fallback: Kupo has no point at or below the cursor)" (const " (Kupo's newest surviving point)") ancestor
            )
        runAttest pool (rollbackTo networkId ourPolicy target)
        updateLocalTip pool (fromMaybe (KupoCheckpoint target "") ancestor)
        liftIO $ threadDelay 1000000
      CursorOnChain -> case chainSyncState of
        UpToDate -> do
          liftIO $ putStrLn "Chain is up to date"
          liftIO $ putStrLn "Sleeping for 10 seconds"
          liftIO $ threadDelay 10000000
        Behind _isWayBehind -> do
          liftIO $ putStrLn "Chain is behind"
          liftIO $ putStrLn "Fetching matches"
          fetchingMatches metricsVar kupoUrl matchPattern ourPolicy networkId pool (ck_slot_no localTip) (ck_slot_no blockchainTip) fetchBatchSize
          updateLocalTip pool blockchainTip
        Ahead -> do
          liftIO $ putStrLn "Chain is ahead"
          let rollbackSlot = max 0 (ck_slot_no blockchainTip - rollbackMargin)
          runAttest pool (rollbackTo networkId ourPolicy rollbackSlot)
          updateLocalTip pool (KupoCheckpoint rollbackSlot "")
          liftIO $ putStrLn ("Rolled back to slot " <> show rollbackSlot <> "; will re-sync forward")
        UpToDateButDifferentBlockHash -> do
          liftIO $ putStrLn "Same slot, different block hash; rolling back with margin"
          let rollbackSlot = max 0 (ck_slot_no blockchainTip - rollbackMargin)
          runAttest pool (rollbackTo networkId ourPolicy rollbackSlot)
          updateLocalTip pool (KupoCheckpoint rollbackSlot "")
