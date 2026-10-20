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
import Palmares.ChainSync.KupoClient (KupoCheckpoint (..))
import Palmares.Storage
  ( currentSchemaVersion,
    ensureAttestSchema,
    putStoredPolicyHexText,
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

defaultConnStr :: String
-- `cexplorer`, which is db-sync's database and the one this service's schema lives beside
-- (ADR 0001 chose one database with role separation over two). The inherited default said
-- `chainsync`, a database no deployment here has: `.env.example` and `Dockerfile.attest-sync`
-- both say `cexplorer`, so the code default was the only place that disagreed.
defaultConnStr = "host=localhost user=postgres password=postgres dbname=cexplorer port=5432"

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
  connStr <- liftIO $ fmap (fromMaybe defaultConnStr) (lookupEnv "PG_CONN_STR")

  let connBS :: ConnectionString = TE.encodeUtf8 (T.pack connStr)
  pool <- runStdoutLoggingT $ createPostgresqlPool connBS 16

  atlasConfig <- maybe (die "Atlas configuration failed") return =<< decodeConfigEnvOrFile "ATLAS_CORE_CONFIG" defaultAtlasCoreConfig
  let networkId = cfgNetworkId atlasConfig

  deployedScriptsContext <- maybe (die "Deployed validators configuration failed") return =<< decodeConfigEnvOrFile @DeployedScriptsContext "DEPLOYED_VALIDATORS_CONFIG" defaultTxBuildingContextFile
  let policyHexText = T.pack $ printf "%s" (getMintingPolicyHash deployedScriptsContext)

  -- Probe the existing schema BEFORE migrating. Wipe (drop) the chain-sync tables if the schema
  -- version or minting policy changed, so migrateAll only CREATEs fresh tables and never runs an
  -- incompatible in-place ALTER (varchar->bigint / ADD COLUMN NOT NULL) that Postgres would reject.
  -- The schema first, and the path pinned to it for everything after: these tables are declared
  -- unqualified, so without this they land in `palmares`, which query-api drops on every boot.
  runSqlPool ensureAttestSchema pool
  mProbe <- runAttest pool readSchemaProbe
  let needWipe = case mProbe of
        Nothing -> False
        Just (storedVersion, storedPolicy) -> storedVersion < currentSchemaVersion || storedPolicy /= policyHexText
  when needWipe $ do
    putStrLn "Schema version or policy changed; dropping chain-sync tables before migration."
    runAttest pool wipeChainSyncTablesRaw
  runAttest pool runMigrations
  runAttest pool (putStoredPolicyHexText policyHexText)

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
    case chainSyncState of
      UpToDate -> do
        liftIO $ putStrLn "Chain is up to date"
        liftIO $ putStrLn "Sleeping for 10 seconds"
        liftIO $ threadDelay 10000000
      Behind _isWayBehind -> do
        liftIO $ putStrLn "Chain is behind"
        liftIO $ putStrLn "Fetching matches"
        fetchingMatches metricsVar kupoUrl matchPattern policyHexText networkId pool (ck_slot_no localTip) (ck_slot_no blockchainTip) fetchBatchSize
        updateLocalTip pool blockchainTip
      Ahead -> do
        liftIO $ putStrLn "Chain is ahead"
        let rollbackSlot = max 0 (ck_slot_no blockchainTip - rollbackMargin)
        runAttest pool (rollbackTo networkId rollbackSlot)
        updateLocalTip pool (KupoCheckpoint rollbackSlot "")
        liftIO $ putStrLn ("Rolled back to slot " <> show rollbackSlot <> "; will re-sync forward")
      UpToDateButDifferentBlockHash -> do
        liftIO $ putStrLn "Same slot, different block hash; rolling back with margin"
        let rollbackSlot = max 0 (ck_slot_no blockchainTip - rollbackMargin)
        runAttest pool (rollbackTo networkId rollbackSlot)
        updateLocalTip pool (KupoCheckpoint rollbackSlot "")
