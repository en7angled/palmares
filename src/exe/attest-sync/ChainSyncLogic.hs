{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Core chain-sync logic: tip comparison and batch match fetching against
-- the Kupo indexer.
module ChainSyncLogic
  ( evaluateChainSyncState,
    reportSyncState,
    CursorCheck (..),
    classifyCursor,
    verifyCursor,
    updateLocalTip,
    getLocalTip,
    getBlockchainTip,
    fetchingMatches,
  )
where

import ChainsyncAPI (ChainSyncState (..), SyncMetrics (..))
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Concurrent.MVar (MVar, modifyMVar_)
import Control.Monad.IO.Class (liftIO)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Persist.Sql (ConnectionPool)
import GeniusYield.Types (GYMintingPolicyId, GYNetworkId, mintingPolicyIdToText)
import Palmares.ChainSync.KupoClient (KupoCheckpoint (..), runKupoCheckpointBySlot, runKupoCheckpointsList, runKupoMatches)
import Palmares.Constants (appVersion)
import Palmares.Storage
  ( AttestSyncState (..),
    ChainCursor (..),
    applyMatches,
    currentSchemaVersion,
    getCursorValue,
    putAttestSyncState,
    putCursor,
    runAttest,
  )

-- | Slot gap beyond which the local tip is considered "way behind" the chain
-- (drives the 'Behind' flag that selects bulk vs incremental fetching).
wayBehindThresholdSlots :: Integer
wayBehindThresholdSlots = 1200

-- | Compare local and blockchain tips to derive the current sync state.
evaluateChainSyncState :: KupoCheckpoint -> KupoCheckpoint -> ChainSyncState
evaluateChainSyncState localTip@(KupoCheckpoint localSlot localHeader) blockchainTip@(KupoCheckpoint blockchainSlot blockchainHeader)
  | localTip == blockchainTip = UpToDate
  | localSlot == blockchainSlot && localHeader /= blockchainHeader = UpToDateButDifferentBlockHash
  | localSlot < blockchainSlot = Behind (blockchainSlot - localSlot > wayBehindThresholdSlots)
  | localSlot > blockchainSlot = Ahead
  -- All cases are covered by the guards above; GHC needs a fallback for exhaustiveness.
  | otherwise = UpToDate

-- | Is the block our cursor names still on the chain Kupo is serving.
--
-- 'CursorOrphaned' carries the newest point at or below the cursor that Kupo still has, which is a
-- rollback target: 'Nothing' only when Kupo knows nothing at or below that slot.
data CursorCheck
  = CursorOnChain
  | CursorOrphaned (Maybe KupoCheckpoint)
  deriving (Show, Eq)

-- | The verdict, given the cursor and what @GET \/v1\/checkpoints\/{slot}@ answered.
--
-- __Kupo's non-strict answer is the ANCESTOR__, measured against a live preprod Kupo v2.12.0: for a
-- slot with a block it returns that block, for a slot without one it returns the newest earlier
-- block, and for a slot above the tip it returns the tip. So one call answers both questions this
-- needs — is our block still there, and if not, what is the newest point that is.
--
-- A cursor with an EMPTY header is a database that has never stored one ('getLocalTip' returns slot
-- 0), and it is on-chain by definition: there is nothing to orphan, and rolling back would be a
-- rollback of nothing.
classifyCursor :: KupoCheckpoint -> Maybe KupoCheckpoint -> CursorCheck
classifyCursor cursor ancestor
  | T.null (ck_header_hash cursor) = CursorOnChain
  | ancestor == Just cursor = CursorOnChain
  | otherwise = CursorOrphaned ancestor

-- | Ask Kupo whether the cursor's block survived. CS-02.
--
-- __Why this exists.__ 'evaluateChainSyncState' consults the header only when the slots are EQUAL,
-- so the common shape of a short fork was invisible: our block is orphaned and Kupo has already
-- applied a replacement at a higher slot, which reads as plain @Behind@. Nothing then deleted the
-- projections of the orphaned block, and any replacement block below our cursor slot fell outside
-- every future fetch window — the registry served state that is not on the canonical chain, and
-- went on serving it. Kupo's own spec warns of exactly this ("outputs may end up in another block
-- than the one they were initially advertised in") and ships the endpoint to detect it; the client
-- for it has existed here, with no callers, since the beginning.
--
-- __A Kupo error is not evidence of a fork__ and must not cause a rollback: it reports
-- 'CursorOnChain' and leaves the tick to the existing path, which already retries the tip fetch.
verifyCursor :: String -> KupoCheckpoint -> IO CursorCheck
verifyCursor kupoUrl cursor
  | T.null (ck_header_hash cursor) = return CursorOnChain
  | otherwise = do
      r <- runKupoCheckpointBySlot kupoUrl (ck_slot_no cursor)
      case r of
        Left _err -> do
          putStrLn "Kupo client error while verifying the cursor's block (treating it as on-chain)"
          return CursorOnChain
        Right ancestor -> return (classifyCursor cursor ancestor)

-- | Write the projector's liveness row — `CS-07`.
--
-- Called on every tick and again after every fetch window, which is the whole point: the CURSOR is
-- written only once a window has been applied in full, so a first sync left @\/ready@ green and
-- @\/profiles@ serving partial pages for hours. This row says what the projector is doing while it
-- is doing it.
--
-- A write failure here must not stop the projector: this is a report about syncing, not part of it.
-- It is logged and the tick continues.
reportSyncState :: ConnectionPool -> GYMintingPolicyId -> T.Text -> KupoCheckpoint -> Integer -> Maybe T.Text -> IO ()
reportSyncState pool ourPolicy state cursor kupoTipSlot mErr = do
  now <- getCurrentTime
  r <-
    try $
      runAttest
        pool
        ( putAttestSyncState
            AttestSyncState
              { attestSyncStateSingleton = True,
                attestSyncStateCursorSlot = ck_slot_no cursor,
                attestSyncStateCursorHash = ck_header_hash cursor,
                attestSyncStateKupoTipSlot = kupoTipSlot,
                attestSyncStateState = state,
                attestSyncStateLastSyncAt = now,
                attestSyncStatePolicyHexText = mintingPolicyIdToText ourPolicy,
                attestSyncStateSchemaVersion = currentSchemaVersion,
                attestSyncStateServiceVersion = T.pack appVersion,
                attestSyncStateLastError = mErr
              }
        )
  case r of
    Right () -> return ()
    Left (e :: SomeException) -> putStrLn ("Could not write the sync-state row (continuing): " <> show e)

-- | Persist the given checkpoint as the new local tip in the database.
updateLocalTip :: ConnectionPool -> KupoCheckpoint -> IO ()
updateLocalTip pool tip = do
  runAttest
    pool
    ( do
        putCursor (ChainCursor True (ck_slot_no tip) (ck_header_hash tip) Nothing Nothing)
    )
  putStrLn $ "Local tip updated to: " <> show tip

-- | Read the last-persisted local tip from the database (slot 0 if none).
getLocalTip :: ConnectionPool -> IO KupoCheckpoint
getLocalTip pool = do
  runAttest
    pool
    ( do
        mCur <- getCursorValue
        case mCur of
          Just cur -> return (KupoCheckpoint (chainCursorSlotNo cur) (chainCursorHeaderHash cur))
          Nothing -> return (KupoCheckpoint 0 "")
    )

-- | Fetch the current blockchain tip from Kupo, retrying on failure.
getBlockchainTip :: String -> IO KupoCheckpoint
getBlockchainTip kupoUrl = do
  eCk <- liftIO $ runKupoCheckpointsList kupoUrl
  case eCk of
    Left _err -> do
      liftIO $ putStrLn "Kupo client error while fetching tip (retrying)"
      liftIO $ putStrLn "Retrying in 10 seconds"
      liftIO $ threadDelay 10000000
      getBlockchainTip kupoUrl
    Right (ck : _) -> return ck
    Right [] -> do
      liftIO $ putStrLn "No checkpoints returned from Kupo"
      liftIO $ threadDelay 10000000
      getBlockchainTip kupoUrl

-- | Recursively fetch and project Kupo matches in batches from @start@ to @end@. The continuation
-- recurses only on success; on error it tail-retries the SAME window. Windows overlap by one slot
-- (Kupo bounds are inclusive) — duplicate-safe via idempotent upserts.
--
-- The protocol policy arrives as a 'GYMintingPolicyId' rather than loose hex because the projection
-- path authenticates each output against it (inherited fix #3); the Kupo query's own @policy_id@
-- filter is rendered back out of it, so the indexer and the projection cannot disagree about which
-- policy is ours.
fetchingMatches :: MVar SyncMetrics -> String -> T.Text -> GYMintingPolicyId -> GYNetworkId -> ConnectionPool -> Integer -> Integer -> Integer -> IO ()
fetchingMatches metricsVar kupoUrl matchPattern ourPolicy networkId pool start end batchSize
  | end <= start = putStrLn "No more matches to fetch"
  | otherwise = do
      let endInterval = if (start + batchSize) > end then end else start + batchSize
      putStrLn ("Fetching matches from " <> show start <> " to " <> show endInterval)
      eMatches <-
        runKupoMatches
          kupoUrl
          matchPattern
          (Just (mintingPolicyIdToText ourPolicy))
          Nothing
          Nothing
          Nothing
          (Just start)
          (Just endInterval)
          Nothing
          Nothing
          (Just "oldest_first")
          False
          False
          True
      case eMatches of
        Left err -> do
          putStrLn "Kupo client error while fetching matches (retrying)"
          putStrLn "Retrying in 10 seconds"
          -- The one failure an operator cannot otherwise see: the projector is alive, the window is
          -- being retried for ever, and every number on `/status` is the one from before it started.
          reportSyncState pool ourPolicy "error" (KupoCheckpoint start "") end (Just (T.pack (show err)))
          threadDelay 10000000
          fetchingMatches metricsVar kupoUrl matchPattern ourPolicy networkId pool start end batchSize
        Right matches -> do
          applyMatches networkId ourPolicy pool matches
          now <- getCurrentTime
          modifyMVar_ metricsVar $ \m -> pure m {smLocalTip = endInterval, smLastSyncTime = now}
          -- Per WINDOW, with an empty hash: the applied slot is known here and the header is not —
          -- only a completed pass knows which block it stopped at, and `updateLocalTip` writes that.
          -- `syncing` is the honest state inside a window even when this is the last one, because
          -- the pass has not returned yet.
          reportSyncState pool ourPolicy "syncing" (KupoCheckpoint endInterval "") end Nothing
          fetchingMatches metricsVar kupoUrl matchPattern ourPolicy networkId pool endInterval end batchSize
