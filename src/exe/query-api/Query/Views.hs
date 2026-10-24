{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The @palmares@ schema DDL, embedded at compile time and applied in one transaction.
--
-- Every object in the schema is a view or a materialized view derived from db-sync, so there is
-- no state to migrate: @000_schema.sql@ drops and re-creates the schema, and the rest of the
-- files rebuild its contents. That makes the bootstrap idempotent, and it makes the failure mode
-- the right one — one 'runSqlPool' call is one transaction, so a syntax error in the last file
-- rolls the whole set back and leaves the previously working schema serving traffic.
--
-- Fail-closed: 'applyPalmaresSchema' 'die's on failure. A query API that came up with a
-- half-applied schema would answer some routes and 500 on others, which is harder to diagnose
-- than a process that refuses to start.
module Query.Views
  ( palmaresSqlFiles,
    applySchemaSql,
    applyPalmaresSchema,
    hasStatement,
  )
where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile, makeRelativeToProject)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Control.Monad.IO.Class (liftIO)
import Database.Persist.Sql (ConnectionPool, Single (..), SqlPersistT, rawExecute, rawSql, runSqlPool, toPersistValue)
import System.Exit (die)

-- | The schema DDL, in the order it must be applied.
--
-- Listed file by file rather than with @embedDir@ on purpose: the order is load-bearing (the
-- schema must exist before anything in it), and an explicit list makes adding a file a visible
-- edit here instead of a silent consequence of a directory listing. An absent file is a compile
-- error, not a runtime one.
palmaresSqlFiles :: [(FilePath, ByteString)]
palmaresSqlFiles =
  [ ("000_schema.sql", $(makeRelativeToProject "sql/000_schema.sql" >>= embedFile)),
    ("010_gov_views.sql", $(makeRelativeToProject "sql/010_gov_views.sql" >>= embedFile)),
    ("020_views.sql", $(makeRelativeToProject "sql/020_views.sql" >>= embedFile)),
    ("030_metrics.sql", $(makeRelativeToProject "sql/030_metrics.sql" >>= embedFile)),
    -- LAST, and that is load-bearing: it grants the serving role USAGE on the schema and SELECT on
    -- ALL TABLES in it, and `ALL TABLES` resolves to the relations that exist when it runs. Placed
    -- any earlier it would miss `palmares.drep_metrics`. See the file's own header for why the
    -- grants cannot live anywhere but inside this transaction.
    ("040_grants.sql", $(makeRelativeToProject "sql/040_grants.sql" >>= embedFile))
  ]

-- | True when a file contains something to execute.
--
-- The view files start life holding only a header comment, because the objects are appended by
-- later tasks; @postgresql-simple@ rejects a query with no command (@execute: Empty query@), so
-- a comment-only file has to be skipped rather than be allowed to fail the whole bootstrap.
-- Only the emptiness decision looks at the stripped text — what gets executed is always the
-- file's own bytes, comments included, so nothing is lost if a @--@ happens to sit inside a
-- string literal.
hasStatement :: ByteString -> Bool
hasStatement =
  not
    . T.null
    . T.strip
    . T.unlines
    . map (fst . T.breakOn "--")
    . T.lines
    . TE.decodeUtf8

-- | Issue each file's bytes in the caller's transaction, in list order, skipping stubs.
--
-- A @lock_timeout@ goes first, and it is not belt-and-braces. @000_schema.sql@ opens with
-- @DROP SCHEMA palmares CASCADE@, which needs an ACCESS EXCLUSIVE lock on every view in it. If a
-- long read is in flight the DROP waits — and while it waits, PostgreSQL queues every NEW reader
-- behind it, so one boot during one slow query stalls the whole database rather than just itself.
-- Observed: a twenty-minute window in which no reader of @palmares.drep@ could run.
--
-- Ten seconds, then the statement fails, the transaction rolls back, and 'applyPalmaresSchema'
-- 'die's. That is the right outcome: a process that cannot take the lock has not applied the
-- schema and must not serve, and a supervisor restarting it will try again once the reader is
-- done. @SET LOCAL@ scopes it to this transaction, so it cannot leak onto a pooled connection
-- that later serves requests.
applySchemaSql :: [(FilePath, ByteString)] -> SqlPersistT IO ()
applySchemaSql files = do
  rawExecute "SET LOCAL lock_timeout = '10s'" []
  mapM_ (\(_, sql) -> rawExecute (TE.decodeUtf8 sql) []) (filter (hasStatement . snd) files)

-- | The DDL as one text, which is what the fingerprint is taken over.
--
-- Postgres computes the hash, not Haskell: the value is stored and compared by the same @md5()@, so
-- the two cannot disagree about the algorithm, and no hashing dependency is added to a service whose
-- whole point is that it boots with a Postgres DSN and nothing else.
schemaFingerprintSource :: T.Text
schemaFingerprintSource = T.concat (map (TE.decodeUtf8 . snd) palmaresSqlFiles)

-- | Apply the whole schema in one transaction, or 'die' — and __only when it has changed__ (`GV-01`).
--
-- __What was wrong.__ `sql/000_schema.sql` opens with @DROP SCHEMA palmares CASCADE@, so every boot
-- rebuilt every view and matview. The rebuild is atomic — Postgres DDL is transactional, so a reader
-- sees the old schema or the new one and never a gap — but @DROP@ takes an AccessExclusiveLock on
-- every object in the schema, so readers BLOCK for the duration and, with @lock_timeout = '10s'@,
-- the boot itself fails if one is holding a lock. One replica makes that a hiccup per restart. More
-- than one makes it a read outage per restart, and a rolling deploy is nothing but restarts.
--
-- __Two changes, and the gate is the one that matters.__ The advisory lock serialises two replicas
-- booting at the same moment, which is a race the previous code simply lost. The FINGERPRINT is what
-- removes the outage: an ordinary restart with unchanged DDL now does three cheap reads and no DDL at
-- all, which is the common case and the one the finding is about.
--
-- __Written last, deliberately.__ The fingerprint table is created after the DDL it describes, so a
-- bootstrap that dies half way leaves no fingerprint and the next boot rebuilds. There is no state
-- in `palmares` to lose — every object in it is derived from db-sync — so redoing the work is always
-- safe and claiming it was done is the only thing that would not be.
--
-- Matview CONTENT is not this function's business either way: the periodic refresh
-- (@PALMARES_VIEW_REFRESH_SECONDS@) owns that, so skipping the rebuild does not skip a refresh.
applyPalmaresSchema :: ConnectionPool -> IO ()
applyPalmaresSchema pool = do
  r <- try (runSqlPool bootstrap pool)
  case r of
    Left (e :: SomeException) -> die ("palmares schema DDL failed: " <> show e)
    Right () -> pure ()
  where
    bootstrap :: SqlPersistT IO ()
    bootstrap = do
      rawExecute "SET LOCAL lock_timeout = '10s'" []
      -- Transaction-scoped, so it is released by the commit or the rollback and never leaks onto a
      -- pooled connection. The key is an arbitrary constant; what matters is that both replicas pick
      -- the same one.
      -- Wrapped in DO/PERFORM because `rawExecute` refuses a statement that returns columns and
      -- `pg_advisory_xact_lock` returns one. A DO block runs in the CURRENT transaction, so the lock
      -- is still transaction-scoped and still released by the commit or the rollback.
      rawExecute "DO $$ BEGIN PERFORM pg_advisory_xact_lock(871237); END $$" []
      unchanged <- fingerprintMatches
      if unchanged
        then liftIO (putStrLn "palmares schema: DDL unchanged, skipping the rebuild (GV-01)")
        else do
          liftIO (putStrLn "palmares schema: DDL changed or absent, rebuilding")
          applySchemaSql palmaresSqlFiles
          rawExecute "CREATE TABLE palmares.schema_fingerprint (fingerprint text NOT NULL)" []
          rawExecute
            "INSERT INTO palmares.schema_fingerprint (fingerprint) VALUES (md5(?))"
            [toPersistValue schemaFingerprintSource]

    fingerprintMatches :: SqlPersistT IO Bool
    fingerprintMatches = do
      present <-
        rawSql
          "SELECT EXISTS (SELECT 1 FROM information_schema.tables \
          \WHERE table_schema = 'palmares' AND table_name = 'schema_fingerprint')"
          []
      case present of
        [Single True] -> do
          rows <-
            rawSql
              "SELECT fingerprint = md5(?) FROM palmares.schema_fingerprint"
              [toPersistValue schemaFingerprintSource]
          pure $ case rows of
            [Single (Just True)] -> True
            _ -> False
        _ -> pure False
