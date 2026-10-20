{-# LANGUAGE OverloadedStrings #-}

-- | Keeping @palmares.drep_metrics@ current: one thread, one @REFRESH@, no scheduler.
--
-- The matview is created @WITH DATA@ by the schema bootstrap, so it is already correct when the
-- process starts serving. This thread exists only to follow the chain afterwards.
--
-- The refresh is decided by comparing a mark — the tip block and the tip epoch — against the mark
-- of the last successful refresh. That single comparison covers every case that matters: the
-- first tick, the tip advancing, an epoch boundary (where the lifecycle @*_epoch@ columns and
-- @drep_distr@ move without a single new row being inserted) and a rollback (where the mark goes
-- backwards). No cursor table is needed, and none exists.
--
-- Failure behaviour is to log and keep looping. A refresh is idempotent and self-healing: the
-- mark is recorded only on success, so a failed attempt is retried on the next tick. Boot is the
-- only fail-closed point in this process.
module Query.Refresh
  ( RefreshMark (..),
    shouldRefresh,
    readRefreshMark,
    refreshDRepMetrics,
    refreshIntervalSeconds,
    runRefreshThread,
  )
where

import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List (isInfixOf)
import Database.Persist.Sql
  ( ConnectionPool,
    Single (..),
    rawExecute,
    rawSql,
    runSqlPool,
    runSqlPoolNoTransaction,
  )
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Where the chain was when the matview was last rebuilt.
data RefreshMark = RefreshMark
  { -- | The tip block number. @block.block_no@ is nullable in db-sync (Byron epoch boundary
    -- blocks carry none), which cannot be the tip of a synced chain; 'COALESCE' to 0 keeps the
    -- decode total rather than making an impossible row crash the thread.
    markBlockNo :: Int64,
    -- | The tip epoch, carried separately because an epoch boundary changes the metrics without
    -- advancing anything else this thread can see.
    markEpochNo :: Int
  }
  deriving (Eq, Show)

-- | Refresh unless the chain is exactly where it was after the last successful refresh.
--
-- One expression, and deliberately so: inequality against 'Nothing' covers the first tick,
-- inequality in 'markBlockNo' covers both a new block and a rollback, and inequality in
-- 'markEpochNo' covers the boundary.
shouldRefresh :: Maybe RefreshMark -> RefreshMark -> Bool
shouldRefresh prev now = prev /= Just now

-- | The current mark, or 'Nothing' when db-sync has no blocks yet.
readRefreshMark :: ConnectionPool -> IO (Maybe RefreshMark)
readRefreshMark pool = do
  rows <-
    runSqlPool
      ( rawSql
          "SELECT COALESCE(block_no, 0)::bigint, epoch_no::int FROM palmares.sync_state"
          []
      )
      pool
  pure $ case rows of
    (Single b, Single e) : _ -> Just (RefreshMark b e)
    [] -> Nothing

-- | @REFRESH MATERIALIZED VIEW CONCURRENTLY@, outside any transaction.
--
-- 'runSqlPoolNoTransaction', not 'runSqlPool': PostgreSQL's @ExecRefreshMatView@ calls
-- @PreventInTransactionBlock@ for @CONCURRENTLY@, so the plain pool runner's @BEGIN@ turns every
-- refresh into @cannot be executed from a function or multi-command string@. Same hazard as
-- @CREATE INDEX CONCURRENTLY@ (D-15), one layer up.
--
-- @CONCURRENTLY@ is what keeps the API answering during a rebuild: it takes no exclusive lock, at
-- the price of needing the unique index @sql/030_metrics.sql@ creates.
refreshDRepMetrics :: ConnectionPool -> IO (Either SomeException ())
refreshDRepMetrics pool =
  try $
    runSqlPoolNoTransaction
      (rawExecute "REFRESH MATERIALIZED VIEW CONCURRENTLY palmares.drep_metrics" [])
      pool
      Nothing

-- | @PALMARES_VIEW_REFRESH_SECONDS@, defaulting to 300.
--
-- A tick is cheap when nothing changed — one row off @palmares.sync_state@ — so the interval only
-- bounds how stale the matview can get. At preprod's ~22.7 s mean block interval, 300 s rebuilds
-- it about every thirteen blocks.
refreshIntervalSeconds :: IO Int
refreshIntervalSeconds = do
  mv <- lookupEnv "PALMARES_VIEW_REFRESH_SECONDS"
  pure $ case mv >>= readMaybe of
    Just n | n > 0 -> n
    _ -> 300

-- | Read the mark, refresh if it moved, record it only on success.
step :: ConnectionPool -> IORef (Maybe RefreshMark) -> IO ()
step pool ref = do
  mark <- readRefreshMark pool
  case mark of
    Nothing -> warn "palmares.sync_state is empty: db-sync has no blocks yet, nothing to refresh"
    Just now -> do
      prev <- readIORef ref
      when (shouldRefresh prev now) $ do
        r <- refreshDRepMetrics pool
        case r of
          Right () -> writeIORef ref (Just now)
          Left e -> warn ("palmares.drep_metrics refresh failed: " <> show e <> hint e)
  where
    -- A dropped matview means a db-sync migration CASCADE'd through it. The fix is a restart,
    -- because the schema bootstrap is what re-creates it; say so here rather than leaving the
    -- operator to deduce it from a bare 42P01.
    hint e
      | "does not exist" `isInfixOf` show e =
          " -- the matview is gone, which is what a db-sync migration's CASCADE does."
            <> " Restart query-api: the boot bootstrap re-creates the whole palmares schema."
      | otherwise = ""

-- | Start the refresh loop. Never returns; the thread cannot die.
--
-- The whole step is wrapped, not just the @REFRESH@: an exception escaping 'forever' would kill
-- the thread silently and stop every future refresh, which is the one failure mode that would
-- make the API serve stale numbers indefinitely without saying anything.
runRefreshThread :: ConnectionPool -> IO ThreadId
runRefreshThread pool = do
  secs <- refreshIntervalSeconds
  ref <- newIORef Nothing
  forkIO . forever $ do
    r <- try (step pool ref)
    case r of
      Left (e :: SomeException) -> warn ("palmares.drep_metrics refresh tick failed: " <> show e)
      Right () -> pure ()
    threadDelay (secs * 1000000)

warn :: String -> IO ()
warn = hPutStrLn stderr . ("[refresh] " <>)
