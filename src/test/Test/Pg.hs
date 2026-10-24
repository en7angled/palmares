{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | A throwaway PostgreSQL database per test, with db-sync's shape already in it.
--
-- The @palmares@ schema is views over db-sync's @public@ schema, so nothing about it can be
-- tested against SQLite: the fixtures need real enums, real domains and real @jsonb@. Each test
-- therefore gets its own database, created and dropped around the body, so tests neither see
-- each other's rows nor depend on ordering.
--
-- @PALMARES_TEST_PG_CONN_STR@ must be set; when it is not, this module 'die's naming the
-- variable rather than skipping, because a database test that silently passes without a
-- database is worse than no test at all.
module Test.Pg
  ( withScratchDb,
    runPg,
    dbsyncSkeletonSql,
  )
where

import Control.Exception (bracket_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Logger (runNoLoggingT)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.Persist.Postgresql (withPostgresqlPool)
import Database.Persist.Sql (ConnectionPool, SqlPersistT, rawExecute, runSqlPool, runSqlPoolNoTransaction)
import System.Environment (lookupEnv)
import System.Exit (die)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Process (getProcessID)

-- | db-sync's enums, domains and the empty tables our views read. Embedded rather than read at
-- run time so the test binary does not depend on the working directory.
dbsyncSkeletonSql :: ByteString
dbsyncSkeletonSql = $(makeRelativeToProject "test/fixtures/dbsync-skeleton.sql" >>= embedFile)

-- | Run a persistent action in its own transaction.
runPg :: ConnectionPool -> SqlPersistT IO a -> IO a
runPg = flip runSqlPool

-- | The admin connection string, or a 'die' naming the variable that is missing.
-- | One counter per process, so two concurrent 'withScratchDb' calls cannot pick the same name.
--
-- @NOINLINE@ and the usual top-level-'IORef' idiom: without it GHC may inline the @unsafePerformIO@
-- and hand each use site its own counter, which is exactly the collision this exists to prevent.
scratchCounter :: IORef Int
scratchCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE scratchCounter #-}

adminConnStr :: IO Text
adminConnStr =
  lookupEnv "PALMARES_TEST_PG_CONN_STR" >>= \case
    Just s | not (null s) -> pure (T.pack s)
    _ ->
      die
        "PALMARES_TEST_PG_CONN_STR is unset. These tests need a PostgreSQL server; set e.g.\n\
        \  PALMARES_TEST_PG_CONN_STR=\"host=localhost user=postgres password=devonly dbname=postgres port=5432\""

-- | Point a libpq keyword/value connection string at a different database. Replaces an existing
-- @dbname=@ word and appends one otherwise, so the caller's host, user, password and port carry
-- over unchanged.
withDbName :: Text -> Text -> Text
withDbName db s =
  T.unwords (filter (not . T.isPrefixOf "dbname=") (T.words s) <> ["dbname=" <> db])

-- | Create @palmares_test_\<pid\>@, apply the db-sync skeleton, run the body against a pool on
-- it, and drop the database afterwards even if the body throws.
--
-- Three details are load-bearing:
--
--   * @CREATE DATABASE@ and @DROP DATABASE@ go through 'runSqlPoolNoTransaction': PostgreSQL
--     forbids both inside a transaction block, and 'runSqlPool' always opens one.
--   * every pool is created with 'withPostgresqlPool', so its connections are closed before the
--     drop runs. A pool left open makes the drop fail with @is being accessed by other users@.
--   * the drop is @WITH (FORCE)@ anyway (PostgreSQL 13+), so a connection leaked by a failing
--     test cannot wedge the next run.
-- The database name is PER CALL, not per process, and that is a correctness property rather than
-- hygiene. With one name per process, two DB-backed cases running at the same time share a database
-- and each one's @DROP … WITH (FORCE)@ kills the other's pool. Measured: @cabal test
-- --test-options='-j4'@ fails 84 of 706 cases — 61 duplicate-key violations, 6 "terminating
-- connection due to administrator command", 2 "database already exists" — while the default
-- single-threaded run fails none. The suite was green only because tasty happened to run it
-- serially, and CI's own comment already claimed the stronger property ("each test creates and drops
-- its own database, so they neither share rows nor depend on order").
withScratchDb :: (ConnectionPool -> IO a) -> IO a
withScratchDb body = do
  admin <- adminConnStr
  pid <- getProcessID
  n <- atomicModifyIORef' scratchCounter (\k -> (k + 1, k))
  let dbName = "palmares_test_" <> T.pack (show pid) <> "_" <> T.pack (show n)
      onAdmin sql =
        runNoLoggingT $ withPostgresqlPool (TE.encodeUtf8 admin) 1 $ \pool ->
          runSqlPoolNoTransaction (rawExecute sql []) pool Nothing
      dropDb = onAdmin ("DROP DATABASE IF EXISTS \"" <> dbName <> "\" WITH (FORCE)")
  bracket_
    (dropDb >> onAdmin ("CREATE DATABASE \"" <> dbName <> "\""))
    dropDb
    ( runNoLoggingT $ withPostgresqlPool (TE.encodeUtf8 (withDbName dbName admin)) 2 $ \pool ->
        liftIO $ do
          runPg pool (rawExecute (TE.decodeUtf8 dbsyncSkeletonSql) [])
          body pool
    )
