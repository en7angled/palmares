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
import Database.Persist.Sql (ConnectionPool, SqlPersistT, rawExecute, runSqlPool)
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
    ("030_metrics.sql", $(makeRelativeToProject "sql/030_metrics.sql" >>= embedFile))
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

-- | Apply the whole schema in one transaction, or 'die'.
applyPalmaresSchema :: ConnectionPool -> IO ()
applyPalmaresSchema pool = do
  r <- try (runSqlPool (applySchemaSql palmaresSqlFiles) pool)
  case r of
    Left (e :: SomeException) -> die ("palmares schema DDL failed: " <> show e)
    Right () -> pure ()
