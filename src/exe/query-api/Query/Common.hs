{-# LANGUAGE OverloadedStrings #-}

-- | Shared pagination, ordering and text-bounding helpers for the query API.
--
-- Everything here exists to stop one of three bugs reaching a client:
--
--   1. an unbounded page, which turns a public endpoint into a way to ask for the whole table;
--   2. an unstable ORDER BY, which makes keyset and offset paging skip rows whenever two rows
--      share a sort key;
--   3. a user string reaching a LIKE pattern or an ORDER BY clause unescaped.
--
-- The governance endpoints page and sort IN SQL. 'legacyApplyLimits' and
-- 'legacyApplyFilterOrderLimit' below slice a Haskell list instead, which is the F-17 bug: the
-- query fetches everything and the handler throws most of it away. They survive only because the
-- inherited profile/attestation handlers still call them, and they are named so that no new code
-- reaches for them by accident. They go when those handlers do.
module Query.Common where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Palmares.DomainTypes.Transfer.OrderBy (SortOrder (..))
import Palmares.WebAPI.Envelope (ErrorCode (..))
import Palmares.WebAPI.Utils (escapeLikePattern)

type Limit = Int

type Offset = Int

-- | The page size an endpoint will serve: a ceiling and the size used when the client asks for
-- none.
--
-- DEVIATION from the plan, which passes the ceiling alone and derives the default from it. That
-- works only while @\/activity@ is the single endpoint with a non-default page size, and it fails
-- silently the moment another endpoint happens to share its ceiling — the handler would get 20
-- rows because of a number it never set. Both values are named here instead, so a call site reads
-- as the endpoint it belongs to rather than as two magic integers.
data PageBounds = PageBounds
  { boundMax :: Int,
    boundDefault :: Int
  }
  deriving (Show, Eq)

-- | JSON list endpoints. 200 is the ceiling a client gets without asking for CSV.
jsonBounds :: PageBounds
jsonBounds = PageBounds 200 50

-- | CSV export. The point of an export is to get the data out in one request, so the ceiling is
-- fifty times the JSON one; the cost is bounded because a CSV row is a few hundred bytes and the
-- query is still a single indexed scan.
csvBounds :: PageBounds
csvBounds = PageBounds 10000 50

-- | @\/activity@. A lower ceiling and a smaller default than the list endpoints, because the feed
-- is a union of eleven arms over millions of rows and a client scrolls it rather than exports it.
activityBounds :: PageBounds
activityBounds = PageBounds 100 20

-- | The bounds implied by an @Accept@ header.
--
-- Matched by prefix, because @text\/csv;charset=utf-8@ is the same request as @text\/csv@ and a
-- client that sends the parameter must not silently get the JSON ceiling.
boundsFor :: Maybe Text -> PageBounds
boundsFor accept
  | Just a <- accept, "text/csv" `T.isPrefixOf` T.strip a = csvBounds
  | otherwise = jsonBounds

-- | The largest @offset@ this API will serve.
--
-- Beyond this a client is deep-offset paging, which PostgreSQL answers by counting past every
-- skipped row; the cursor endpoints exist for that case. It is a REJECTION rather than a clamp
-- because clamping would silently serve the wrong page, and a client reading row 10,001 has no
-- way to notice.
hardOffsetCeiling :: Int
hardOffsetCeiling = 10000

-- | Clamp the requested page into the endpoint's bounds, or refuse.
--
-- A limit outside the range is clamped silently: both @0@ and @999@ have an obvious intended
-- meaning, and the applied value goes back in the response envelope so a client can see what it
-- got. A negative offset clamps to 0 for the same reason. A too-large offset does not, per
-- 'hardOffsetCeiling'.
normalizeLimitOffset :: PageBounds -> Maybe Int -> Maybe Int -> Either ErrorCode (Limit, Offset)
normalizeLimitOffset (PageBounds maxLimit defLimit) limit offset
  | off > hardOffsetCeiling = Left OffsetTooLarge
  | otherwise = Right (max 1 (min maxLimit (fromMaybe defLimit limit)), off)
  where
    off = max 0 (fromMaybe 0 offset)

-- | The column, null placement and tiebreaker an endpoint sorts by.
--
-- Both column names come from a closed per-endpoint @*OrderBy -> SortSpec@ total function, never
-- from request text, which is what keeps 'orderClause' safe to splice into SQL.
data SortSpec = SortSpec
  { sortColumn :: Text,
    sortNullsLast :: Bool,
    sortTiebreaker :: Text
  }
  deriving (Show, Eq)

-- | Render a stable @ORDER BY@.
--
-- The tiebreaker is ALWAYS appended, ascending. Without it, two rows sharing the sort key — two
-- DReps with the same voting power, two votes in the same slot — may come back in either order
-- on either page, and a client paging through them skips some and sees others twice. That is not
-- a theoretical ordering concern: it is the defect that makes a leaderboard lose rows.
--
-- @NULLS LAST@ is per-column rather than always-on, because it is only right where NULL means
-- \"not applicable\": a DRep with no participation rate belongs after one with 0%, but a name
-- that happens to be NULL has no such reading.
orderClause :: SortSpec -> SortOrder -> Text
orderClause (SortSpec col nullsLast tiebreak) order =
  "ORDER BY " <> col <> " " <> dir <> nulls <> ", " <> tiebreak <> " ASC"
  where
    dir = case order of
      Asc -> "ASC"
      Desc -> "DESC"
    nulls = if nullsLast then " NULLS LAST" else ""

-- | A case-insensitive, fully escaped @LIKE@ pattern.
--
-- Lowercased because the matching columns are compared lowercased; escaped because a @%@ or @_@
-- a user typed is a character they are searching for, not a wildcard they are setting. Without
-- the escape, searching for \"100%\" matches every row.
likePat :: Text -> Text
likePat t = "%" <> escapeLikePattern (T.toLower t) <> "%"

-- | Trim a search query and bound its length.
--
-- The bounds are not arbitrary: below two characters a trigram index cannot help and the query
-- degenerates into a full scan of every searchable column, and above a hundred the input is not a
-- search any more. Absent is fine — it means \"no filter\" — but blank is too short, because a
-- client that sent spaces asked for something.
normalizeQ :: Maybe Text -> Either ErrorCode (Maybe Text)
normalizeQ Nothing = Right Nothing
normalizeQ (Just raw)
  | T.length q < 2 = Left QueryTooShort
  | T.length q > 100 = Left QueryTooLong
  | otherwise = Right (Just q)
  where
    q = T.strip raw

-- | Refuse an inverted time or epoch range.
--
-- An empty page would be a defensible answer and is the wrong one: the client asked a question
-- that cannot have results, and \"no rows\" reads as \"nothing happened in that window\". A 400
-- says which parameter pair is wrong.
checkRanges :: Maybe UTCTime -> Maybe UTCTime -> Maybe Int -> Maybe Int -> Either ErrorCode ()
checkRanges fromTime toTime fromEpoch toEpoch
  | Just a <- fromTime, Just b <- toTime, a > b = Left InvalidTimeRange
  | Just a <- fromEpoch, Just b <- toEpoch, a > b = Left InvalidEpochRange
  | otherwise = Right ()

-- | Normalize optional order_by and sort_order; default sort order when only order_by given is Asc.
normalizeOrder :: Maybe a -> Maybe SortOrder -> Maybe (a, SortOrder)
normalizeOrder orderBy sortOrder = case (orderBy, sortOrder) of
  (Just ob, Just so) -> Just (ob, so)
  (Just ob, Nothing) -> Just (ob, Asc)
  _ -> Nothing

-- | Normalize optional limit/offset for the INHERITED profile/attestation handlers.
--
-- Kept only for them. New code uses 'normalizeLimitOffset', which refuses a deep offset instead
-- of serving it and carries its endpoint's bounds rather than a fixed 100/500.
legacyNormalizeLimitOffset :: Maybe Int -> Maybe Int -> Maybe (Int, Int)
legacyNormalizeLimitOffset limit offset =
  Just (clampLimit (fromMaybe 100 limit), max 0 (fromMaybe 0 offset))
  where
    clampLimit l = max 1 (min 500 l)

-- | Slice a list by the given limit and offset. 'Nothing' returns all items.
--
-- The F-17 shape: the query already fetched every row. Inherited handlers only — see the module
-- header.
legacyApplyLimits :: Maybe (Limit, Offset) -> [a] -> [a]
legacyApplyLimits Nothing xs = xs
legacyApplyLimits (Just (limit, offset)) xs =
  let safeLimit = Prelude.max 0 limit
      safeOffset = Prelude.max 0 offset
   in Prelude.take safeLimit (Prelude.drop safeOffset xs)

-- | Apply optional filter, then optional ordering, then optional limit/offset.
-- Caller supplies the list and the two optional-argument list transformers.
--
-- Inherited handlers only — see the module header.
legacyApplyFilterOrderLimit ::
  Maybe (Limit, Offset) ->
  Maybe f ->
  Maybe (ob, SortOrder) ->
  (Maybe f -> [a] -> [a]) ->
  (Maybe (ob, SortOrder) -> [a] -> [a]) ->
  [a] ->
  [a]
legacyApplyFilterOrderLimit maybeLimitOffset maybeFilter maybeOrder applyFilter applyOrder =
  legacyApplyLimits maybeLimitOffset . applyOrder maybeOrder . applyFilter maybeFilter

-- | The epoch-power series: at most 200 points, which is also the default.
--
-- Default equal to the ceiling, unlike every other endpoint, because the series IS the answer —
-- a client asking for a DRep's power history wants the history, not its first fifty epochs. 200
-- epochs is about two and a half years on Cardano.
epochSeriesBounds :: PageBounds
epochSeriesBounds = PageBounds 200 200
