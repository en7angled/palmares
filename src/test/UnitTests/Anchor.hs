{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Golden test for @palmares.anchor@'s single verdict column (D-10).
--
-- One seeded anchor per verdict, so every arm of the @CASE@ is exercised and the arm ORDER is
-- pinned: the @data:@ row also carries a URL-parse failure row, so it would read @unreachable@
-- if @inline@ were not tested first.
--
-- The three failure strings are the real ones db-sync persists (@show@ over
-- @OffChainFetchError@, i.e. prose, not constructor names) — verified against the live preprod
-- database, where they classify 66 anchors as @hash_mismatch@ and 237 as @unreachable@. Matching
-- constructor names instead would have made every failure read @unreachable@.
module UnitTests.Anchor (tests) where

import Data.Text (Text)
import Database.Persist.Sql (Single (..), rawExecute, rawSql)
import Query.Views (applyPalmaresSchema)
import Test.Pg (runPg, withScratchDb)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testCase "anchor verdicts, seeded rows" $ withScratchDb $ \pool -> do
    applyPalmaresSchema pool
    runPg pool $ rawExecute seedRows []
    verdicts <-
      runPg pool $
        rawSql "SELECT url, verdict, cip100_valid FROM palmares.anchor ORDER BY voting_anchor_id" []
    map (\(Single u, Single v, Single c) -> (u :: Text, v :: Text, c :: Maybe Bool)) verdicts
      @?= [ ("https://ok.example/a.jsonld", "valid", Just True),
            ("https://schema.example/b.jsonld", "invalid_schema", Just False),
            -- is_valid IS NULL: db-sync writes it when the CIP-100 check is inconclusive, and
            -- preprod really has one such row. It collapses into invalid_schema, and
            -- cip100_valid is what keeps "failed" distinguishable from "inconclusive".
            ("https://inconclusive.example/c.jsonld", "invalid_schema", Nothing),
            ("https://mismatch.example/d.jsonld", "hash_mismatch", Nothing),
            ("https://big.example/e.jsonld", "oversized", Nothing),
            -- the default arm: never a false accusation, just "the fetch failed"
            ("ftp://nope.example/f.jsonld", "unreachable", Nothing),
            ("data:text/plain;utf8,Approve parameter change action on preprod testnet", "inline", Nothing),
            ("https://queued.example/h.jsonld", "not_fetched", Nothing)
          ]

-- | Seed rows.
--
-- @off_chain_vote_data@ carries @json jsonb NOT NULL@, @bytes bytea NOT NULL@ and
-- @language varchar NOT NULL@ in the real db-sync schema, so all three are supplied here. The
-- plan's draft of this seed omitted them; it would have failed against preprod and against the
-- generated shape fixture alike.
seedRows :: Text
seedRows =
  "INSERT INTO public.voting_anchor (id, block_id, data_hash, url, type) VALUES \
  \ (1,1,'\\x01','https://ok.example/a.jsonld','vote'), \
  \ (2,1,'\\x02','https://schema.example/b.jsonld','vote'), \
  \ (3,1,'\\x03','https://inconclusive.example/c.jsonld','vote'), \
  \ (4,1,'\\x04','https://mismatch.example/d.jsonld','vote'), \
  \ (5,1,'\\x05','https://big.example/e.jsonld','vote'), \
  \ (6,1,'\\x06','ftp://nope.example/f.jsonld','vote'), \
  \ (7,1,'\\x07','data:text/plain;utf8,Approve parameter change action on preprod testnet','vote'), \
  \ (8,1,'\\x08','https://queued.example/h.jsonld','vote'); \
  \ INSERT INTO public.off_chain_vote_data (id, voting_anchor_id, hash, json, bytes, language, is_valid) VALUES \
  \ (1,1,'\\x01','{}'::jsonb,'\\x7b7d','en',TRUE), \
  \ (2,2,'\\x02','{}'::jsonb,'\\x7b7d','en',FALSE), \
  \ (3,3,'\\x03','{}'::jsonb,'\\x7b7d','en',NULL); \
  \ INSERT INTO public.off_chain_vote_fetch_error (id, voting_anchor_id, fetch_error, fetch_time, retry_count) VALUES \
  \ (1,4,'Hash mismatch when fetching metadata from https://mismatch.example/d.jsonld. Expected \"ab\" but got \"cd\".','2026-10-19 00:00:00',0), \
  \ (2,5,'Error Offchain Voting Anchor: Size error, fetching metadata from https://big.example/e.jsonld exceeded 512 bytes.','2026-10-19 00:00:00',0), \
  \ (3,6,'Error Offchain Voting Anchor: URL parse error for ftp://nope.example/f.jsonld','2026-10-19 00:00:00',2), \
  \ (4,7,'Error Offchain Voting Anchor: URL parse error for data:text/plain;utf8,Approve parameter change action on preprod testnet','2026-10-19 00:00:00',1);"
