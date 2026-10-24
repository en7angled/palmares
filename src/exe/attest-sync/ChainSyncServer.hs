{-# LANGUAGE OverloadedStrings #-}

module ChainSyncServer (startProbeServer) where

import ChainsyncAPI (SyncMetrics (..), mkServiceProbeApp)
import Control.Concurrent.MVar (MVar)
import Data.String (fromString)
import Database.Persist.Sql (ConnectionPool)
import Network.Wai.Handler.Warp (HostPreference, defaultSettings, runSettings, setHost, setPort)
import Palmares.WebAPI.CORS (CorsConfig)

-- | Serve @\/health@ and @\/ready@ on @port@.
--
-- The pool and the readiness threshold are passed straight through to 'mkServiceProbeApp': the
-- probes measure the database per request and compare the tick's age against the same threshold
-- @main@ gives the tip comparison.
startProbeServer :: CorsConfig -> Int -> ConnectionPool -> Integer -> MVar SyncMetrics -> IO ()
startProbeServer corsCfg port pool maxLagSlots metricsVar = do
  let host = "0.0.0.0"
  putStrLn $ "Starting chain-sync probe server at " <> host <> " " <> show port
  let settings = setHost (fromString host :: HostPreference) $ setPort port defaultSettings
  let app = mkServiceProbeApp corsCfg pool maxLagSlots metricsVar
  runSettings settings app
