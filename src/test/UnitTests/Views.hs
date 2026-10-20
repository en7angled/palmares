{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Tests for the @palmares@ schema bootstrap: that it applies, that applying it twice is a
-- no-op, that the embedded file set is exactly the four files in lexical order, and that a
-- failing statement anywhere in the set leaves the previous schema intact.
module UnitTests.Views (tests) where

import Control.Exception (SomeException, try)
import Data.Either (isLeft)
import Database.Persist.Sql (Single (..), SqlPersistT, rawExecute, rawSql)
import Query.Views (applyPalmaresSchema, applySchemaSql, hasStatement, palmaresSqlFiles)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "palmares schema bootstrap"
    [ testCase "applies, and applies again (DROP SCHEMA CASCADE makes it idempotent)" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          applyPalmaresSchema pool
          [Single (n :: Int)] <-
            runPg pool $ rawSql "SELECT count(*)::int FROM pg_namespace WHERE nspname = 'palmares'" []
          n @?= 1,
      testCase "every file in palmaresSqlFiles is applied, in lexical order" $
        map fst palmaresSqlFiles
          @?= ["000_schema.sql", "010_gov_views.sql", "020_views.sql", "030_metrics.sql"],
      testCase "a comment-only file is a stub and is skipped, not executed" $ do
        hasStatement "-- nothing here yet\n" @?= False
        hasStatement "   \n\n-- still nothing\n   \n" @?= False
        hasStatement "-- a header\nCREATE SCHEMA x;\n" @?= True
        hasStatement "CREATE SCHEMA x; -- trailing comment\n" @?= True,
      -- Which files are stubs changes as later tasks fill them, so the assertion is the
      -- invariant and not today's snapshot: 000 is never skipped (nothing else can run without
      -- the schema), and filtering never reorders.
      testCase "000_schema.sql is always applied, and filtering preserves order" $ do
        let applied = map fst (filter (hasStatement . snd) palmaresSqlFiles)
        assertBool "000_schema.sql must never be skipped" ("000_schema.sql" `elem` applied)
        applied @?= filter (`elem` applied) (map fst palmaresSqlFiles),
      testCase "a failing statement rolls the whole set back — the previous schema survives" $
        withScratchDb $ \pool -> do
          applyPalmaresSchema pool
          -- A marker object, so "the previous schema survived" is a positive assertion and not
          -- just "the count is still zero" (the stub files create nothing yet).
          runPg pool $ rawExecute "CREATE VIEW palmares.marker AS SELECT 1 AS one" []
          [Single (relsBefore :: Int)] <- runPg pool countPalmaresRelations
          r <-
            try @SomeException $
              runPg pool (applySchemaSql [("999_bad.sql", "DROP SCHEMA palmares CASCADE; SELECT 1/0;")])
          assertBool "the bad set must fail" (isLeft r)
          [Single (relsAfter :: Int)] <- runPg pool countPalmaresRelations
          relsAfter @?= relsBefore
          assertBool "the marker view must still be there" (relsBefore >= 1)
    ]
  where
    countPalmaresRelations :: SqlPersistT IO [Single Int]
    countPalmaresRelations =
      rawSql
        "SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
        \WHERE n.nspname = 'palmares'"
        []
