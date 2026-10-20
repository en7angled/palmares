{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The query API's input bounds, its ordering stability, and the CSV trust boundary.
--
-- Every case here is a client-visible failure someone would otherwise have to reproduce against a
-- running server: a page that skips rows, a search that matches everything, an empty page where a
-- 400 belonged, a spreadsheet that runs a formula out of exported data.
module UnitTests.QueryHardening (queryHardeningTests) where

import Data.Csv (DefaultOrdered (..), FromNamedRecord (..), ToNamedRecord (..), decodeByName, header, namedRecord, (.:), (.=))
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import Data.Vector qualified as V
import Palmares.DomainTypes.Transfer.OrderBy (SortOrder (..))
import Palmares.WebAPI.CSV (CSV, safeCell)
import Palmares.WebAPI.Envelope (ErrorCode (..), Page (..))
import Palmares.WebAPI.Utils (escapeLikePattern)
import Query.Common
import Servant (Accept (..), MimeRender (..))
import Test.Tasty
import Test.Tasty.HUnit

-- | A one-column row, so the CSV assertions are about the encoder rather than about a DTO.
newtype Row = Row {rowCell :: T.Text}
  deriving (Show, Eq)

instance ToNamedRecord Row where
  toNamedRecord (Row c) = namedRecord ["cell" .= safeCell c]

instance DefaultOrdered Row where
  headerOrder _ = header ["cell"]

instance FromNamedRecord Row where
  parseNamedRecord r = Row <$> r .: "cell"

queryHardeningTests :: TestTree
queryHardeningTests = testGroup "query hardening" [boundsTests, csvTests]

boundsTests :: TestTree
boundsTests =
  testGroup
    "bounds, ordering and patterns"
    [ testCase "limit clamps silently to [1, maxLimit] and offset to >= 0" $
        map
          (\(b, l, o) -> normalizeLimitOffset b l o)
          [(jsonBounds, Just 999, Just (-5)), (jsonBounds, Just 0, Nothing), (jsonBounds, Nothing, Just 10)]
          @?= [Right (200, 0), Right (1, 0), Right (50, 10)],
      -- Clamping a too-large offset would silently serve the wrong page, and a client reading row
      -- 10,001 has no way to notice.
      testCase "offset past the hard ceiling is rejected, never clamped" $
        normalizeLimitOffset jsonBounds (Just 50) (Just 10001) @?= Left OffsetTooLarge,
      testCase "boundsFor reads the Accept header: CSV 10000, otherwise 200" $
        map
          (boundMax . boundsFor)
          [Just "text/csv", Just "text/csv;charset=utf-8", Just "application/json", Nothing]
          @?= [10000, 10000, 200, 200],
      testCase "/activity ceiling is 100 with default 20" $
        (boundMax activityBounds, normalizeLimitOffset activityBounds Nothing Nothing)
          @?= (100, Right (20, 0)),
      -- Equal keys otherwise reshuffle between pages and rows get skipped.
      testCase "orderClause always appends the ASC tiebreaker and NULLS LAST" $
        ( orderClause (SortSpec "m.voting_power" True "d.drep_hash_id") Desc,
          orderClause (SortSpec "d.given_name" False "d.drep_hash_id") Asc
        )
          @?= ( "ORDER BY m.voting_power DESC NULLS LAST, d.drep_hash_id ASC",
                "ORDER BY d.given_name ASC, d.drep_hash_id ASC"
              ),
      testCase "likePat lowercases, escapes, and wraps in %" $
        likePat "100%_X\\" @?= "%100\\%\\_x\\\\%",
      -- The composition order in escapeLikePattern is load-bearing (right to left): escaping the
      -- backslash last would double the backslashes the other two replacements just introduced.
      testCase "a literal backslash survives as exactly one escaped backslash" $
        escapeLikePattern "\\%" @?= "\\\\\\%",
      testCase "q is trimmed then bounded to [2,100]" $
        map normalizeQ [Just "  ab  ", Just " a ", Just (T.replicate 101 "x"), Nothing]
          @?= [Right (Just "ab"), Left QueryTooShort, Left QueryTooLong, Right Nothing],
      -- An empty page reads as "nothing happened in that window", which is a different and false
      -- answer to a question that cannot have results.
      testCase "inverted ranges are 400s, not empty pages" $
        ( checkRanges (Just t2) (Just t1) Nothing Nothing,
          checkRanges Nothing Nothing (Just 320) (Just 300),
          checkRanges (Just t1) (Just t2) (Just 300) (Just 320)
        )
          @?= (Left InvalidTimeRange, Left InvalidEpochRange, Right ())
    ]
  where
    t1 = read "2026-01-01 00:00:00 UTC"
    t2 = read "2026-02-01 00:00:00 UTC"

csvTests :: TestTree
csvTests =
  testGroup
    "CSV export"
    [ testCase "content type is text/csv;charset=utf-8" $
        contentType (Proxy @CSV) @?= "text/csv;charset=utf-8",
      -- Exported governance data lands in spreadsheets: this is a trust boundary, not a nicety.
      testCase "formula-injection guard prefixes the five dangerous leads" $
        map safeCell ["=1+1", "+1", "-1", "@SUM(A1)", "\t=x", "\r=x", "plain", "-", ""]
          @?= ["'=1+1", "'+1", "'-1", "'@SUM(A1)", "'\t=x", "'\r=x", "plain", "'-", ""],
      testCase "a cell containing a comma, a quote and a newline survives a round trip" $
        decodeByName (mimeRender (Proxy @CSV) (Page [Row "a,b\"c\nd"] (Just 1) 1 0 Nothing))
          @?= Right (header ["cell"], V.fromList [Row "a,b\"c\nd"]),
      testCase "the envelope is dropped: CSV is rows only, with one header line" $
        mimeRender (Proxy @CSV) (Page [Row "x", Row "y"] (Just 2) 2 0 Nothing)
          @?= "cell\r\nx\r\ny\r\n"
    ]
