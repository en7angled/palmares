{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- | The query API's input bounds, its ordering stability, and the CSV trust boundary.
--
-- Every case here is a client-visible failure someone would otherwise have to reproduce against a
-- running server: a page that skips rows, a search that matches everything, an empty page where a
-- 400 belonged, a spreadsheet that runs a formula out of exported data.
module UnitTests.QueryHardening (queryHardeningTests) where

import Data.Aeson (Value (Bool, Object, String), encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.Csv (DefaultOrdered (..), FromNamedRecord (..), ToNamedRecord (..), decodeByName, header, namedRecord, (.:), (.=))
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Proxy (Proxy (..))
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Types (hContentType, methodNotAllowed405, notAcceptable406, ok200, statusCode)
import Network.Wai (defaultRequest, responseHeaders, responseLBS, responseStatus, responseToStream)
import Network.Wai.Internal (ResponseReceived (..))
import Palmares.DomainTypes.Core.Ids (ccColdIdCip129, ccHotIdCip129, drepIdCip105, drepIdCip129)
import Palmares.DomainTypes.Core.Types
  ( AnchorStatus (..),
    AttestationType (..),
    DRepStatus (..),
    GovActionId (..),
    LevelOneAnchorStatus (..),
    ProfileRefAC,
    VoterRole (..),
  )
import Palmares.DomainTypes.Transfer.Filters
  ( AttestationRecordFilter (..),
    DRepFilter (..),
    VoteFilter (..),
    emptyAttestationRecordFilter,
    emptyVoteFilter,
    GovActivityFilter (..),
    emptyDRepFilter,
    emptyGovActivityFilter,
  )
import Palmares.DomainTypes.Transfer.OrderBy (DRepsOrderBy (..), SortOrder (..), VotesOrderBy (..))
import Palmares.WebAPI.CSV (CSV, safeCell)
import Palmares.WebAPI.Envelope (ApiError (..), ErrorCode (..), Page (..), errorCodeFromText, errorCodeToHttpStatus)
import Palmares.WebAPI.Errors (errorCodeFromParserMessage, genericErrorMessage, refusedRequestMiddleware)
import Palmares.Utils (jsonTag)
import Palmares.WebAPI.Utils (escapeLikePattern, markNullableFields)
import Query.Attest (anchorStatusOf, attestationWhere, canonicalGovCredential, credentialIsScript, profileRefOfUserToken)
import Query.Common
import Servant (FromHttpApiData (..))
import Palmares.DomainTypes.Transfer.QueryResponses (ActivityCursor (..), renderCursor)
import Query.Gov
  ( FeedDir (..),
    VoteJoins (..),
    activityWhere,
    activityWindows,
    drepFacetsSql,
    drepSortSpec,
    drepStatusExpr,
    drepWhere,
    effectiveDRepStatus,
    parseCursor,
    registeredDRepStatuses,
    searchSql,
    voteBaseFrom,
    voteBaseSortSpec,
    voteBaseWhere,
    voteJoinsFor,
  )
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
queryHardeningTests =
  testGroup
    "query hardening"
    [ boundsTests,
      csvTests,
      cursorTests,
      errorCodeTests,
      voteStageTests,
      credentialRoleTests,
      userTokenTests,
      issuerAttributionTests,
      nullabilityTests,
      refusalTests,
      anchorVerdictTests
    ]

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
      -- The sort table is a CLOSED total function, which is the only reason splicing a column
      -- name into an ORDER BY is safe: no request text can reach the clause.
      testCase "every DRepsOrderBy maps to a whitelisted column with a tiebreaker" $
        map
          (\o -> (sortColumn (drepSortSpec o), sortTiebreaker (drepSortSpec o)))
          ([minBound .. maxBound] :: [DRepsOrderBy])
          @?= map
            (,"d.drep_hash_id")
            [ "d.drep_hash_id",
              "m.voting_power",
              "m.delegator_count",
              "m.participation_rate",
              "m.rationale_rate",
              "d.first_cert_slot",
              "m.votes_cast",
              "d.given_name"
            ],
      testCase "the rate-like columns sort NULLS LAST in both directions" $
        map
          (orderClause (drepSortSpec DRepsOrderByParticipationRate))
          [Asc, Desc]
          @?= [ "ORDER BY m.participation_rate ASC NULLS LAST, d.drep_hash_id ASC",
                "ORDER BY m.participation_rate DESC NULLS LAST, d.drep_hash_id ASC"
              ],
      -- Measured: the status CASE has no arm for a credential with no certificate, so without the
      -- unconditional exclusion the default page published 7 non-DReps as "inactive" and the
      -- total read 301 instead of 294.
      testCase "never-registered credentials are excluded unconditionally, not by the status filter" $
        let (w, _) = drepWhere emptyDRepFilter
         in assertBool
              ("the WHERE must exclude never_registered: " <> T.unpack w)
              ("d.registration_status <> 'never_registered'" `T.isInfixOf` w),
      -- An empty repeatable parameter is NO filter, never "match nothing": asking for no
      -- particular anchor status is asking for any. The three placeholders that ARE there on the
      -- empty filter are the default status set, which is the one deliberate default. Three and not
      -- two since the `unknown` status landed — these two counts are what caught the default set and
      -- the bind list going out of step when it did.
      testCase "an empty repeatable filter adds no clause" $
        let (w, ps) = drepWhere emptyDRepFilter
         in (T.count "a.verdict" w, T.count "?" w, length ps) @?= (0, 3, 3),
      testCase "a repeatable filter expands one placeholder per value" $
        let (w, ps) = drepWhere emptyDRepFilter {drepFilterAnchorStatus = [AnchorValid, AnchorInline]}
         in (T.count "?" w, length ps) @?= (5, 5), -- 3 default statuses + 2 anchor values
      -- Every clause must bring exactly its own placeholders, or the bind list and the statement
      -- fall out of step and postgresql-simple refuses the query at run time with a count
      -- mismatch. Asserting it here turns that into a test failure.
      testCase "the placeholder count always matches the parameter count" $
        mapM_
          ( \f ->
              let (w, ps) = drepWhere f
               in assertEqual (T.unpack w) (T.count "?" w) (length ps)
          )
          [ emptyDRepFilter,
            emptyDRepFilter {drepFilterStatus = [DRepRetired]},
            emptyDRepFilter {drepFilterAnchorStatus = [AnchorValid]},
            emptyDRepFilter {drepFilterHasScript = Just True, drepFilterMinDelegators = Just 3},
            emptyDRepFilter {drepFilterQ = Just "abc", drepFilterLanguage = Just "en-us"},
            emptyDRepFilter {drepFilterActiveInEpoch = Just 320},
            emptyDRepFilter {drepFilterVotedOn = Just (GovActionId (T.replicate 64 "a" <> "#0"))},
            emptyDRepFilter {drepFilterNotVotedOn = Just (GovActionId (T.replicate 64 "b" <> "#1"))}
          ],
      -- Nine parameter groups in one bind list, and postgresql-simple only reports a mismatch at
      -- run time, with a count rather than a name. Same check as the one above, over the facet
      -- statement the DRep explorer page serves.
      testCase "the facet statement's placeholder count matches its parameter count" $
        mapM_
          ( \f ->
              let (sql, ps) = drepFacetsSql f
               in assertEqual (T.unpack (T.takeEnd 240 sql)) (T.count "?" sql) (length ps)
          )
          [ emptyDRepFilter,
            emptyDRepFilter {drepFilterStatus = [DRepRetired]},
            emptyDRepFilter {drepFilterAnchorStatus = [AnchorValid, AnchorInline]},
            emptyDRepFilter {drepFilterLanguage = Just "en-us"},
            emptyDRepFilter
              { drepFilterStatus = [DRepActive],
                drepFilterAnchorStatus = [AnchorValid],
                drepFilterLanguage = Just "en-us",
                drepFilterQ = Just "abc",
                drepFilterMinDelegators = Just 3
              }
          ],
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

cursorTests :: TestTree
cursorTests =
  testGroup
    "the activity cursor"
    [ -- The wire format has one definition ('renderCursor') and one inverse ('parseCursor'), in
      -- two different modules and two different libraries. This is the only thing that holds them
      -- together.
      testCase "render and parse are inverses, negative tx_index included" $
        map (parseCursor . renderCursor) cursors @?= map Right cursors,
      -- The five epoch-boundary arms carry tx_index = -1 and the treasury-enactment arm -2. A
      -- parser that rejected a leading minus would refuse to page past the first ratified action,
      -- and it would do it with a 400 that named no cause.
      testCase "the two epoch-boundary tx_index values parse" $
        map parseCursor ["100:-1:7:42", "100:-2:11:42"]
          @?= [Right (ActivityCursor 100 (-1) 7 42), Right (ActivityCursor 100 (-2) 11 42)],
      testCase "anything that is not four integers is an invalid_cursor 400" $
        map
          parseCursor
          [ "",
            "1:2:3",
            "1:2:3:4:5",
            "a:2:3:4",
            "1:2:3:x",
            "1::3:4",
            " 1:2:3:4",
            "(1):2:3:4",
            "1 :2:3:4",
            "1:2:3:4 ",
            "-:2:3:4",
            "1:2:3:0x4"
          ]
          @?= replicate 12 (Left InvalidCursor),
      -- A cursor page MUST carry a scalar upper bound beside the row comparison: the row
      -- comparison is opaque to the planner, so without it the window reaches no arm and the page
      -- is the 4.6 s unbounded one. This is the assertion that would catch its removal.
      testCase "a windowed cursor page binds both scalar bounds and the row comparison" $
        let (sql, ps) =
              activityWhere emptyGovActivityFilter Older (Just (ActivityCursor 9 8 7 6)) (Just (9 - 432000), Just 9)
         in ( T.count "?" sql == length ps,
              T.isInfixOf "(sort_slot, tx_index, arm, item_index) < (?, ?, ?, ?)" sql,
              T.isInfixOf "sort_slot >= ?" sql,
              T.isInfixOf "sort_slot <= ?" sql
            )
              @?= (True, True, True, True),
      -- The last rung drops the LOWER bound only. The upper bound stays, because it is the one
      -- the planner can push into the eleven arms; without it the rung is unbounded in both
      -- directions and the arms read the whole chain.
      testCase "the last rung drops the lower bound and keeps the upper one" $
        let (sql, ps) = activityWhere emptyGovActivityFilter Older (Just (ActivityCursor 9 8 7 6)) (Nothing, Just 9)
         in (T.count "?" sql == length ps, T.isInfixOf "sort_slot >=" sql, T.isInfixOf "sort_slot <= ?" sql, length ps)
              @?= (True, False, True, 5),
      -- The direction decides the keyset comparison AND the ORDER BY together. If they ever
      -- disagree the feed returns the wrong end of the range and still looks like a page.
      testCase "since reverses the keyset comparison and pins the cursor as the LOWER bound" $
        let (sql, ps) = activityWhere emptyGovActivityFilter Newer (Just (ActivityCursor 9 8 7 6)) (Just 9, Just 100)
         in ( T.count "?" sql == length ps,
              T.isInfixOf "(sort_slot, tx_index, arm, item_index) > (?, ?, ?, ?)" sql,
              T.isInfixOf "sort_slot >= ?" sql,
              T.isInfixOf "sort_slot <= ?" sql
            )
              @?= (True, True, True, True),
      -- Every filter combination, since postgresql-simple counts placeholders lexically and only
      -- complains at run time.
      testCase "every activity filter shape binds as many values as it has placeholders" $
        mapM_
          ( \(f, mc, mw) ->
              let (sql, ps) = activityWhere f Older mc mw
               in assertEqual (T.unpack sql) (T.count "?" sql) (length ps)
          )
          [ (emptyGovActivityFilter, Nothing, (Nothing, Nothing)),
            (emptyGovActivityFilter, Nothing, (Nothing, Just 100)),
            (emptyGovActivityFilter, Nothing, (Just 1, Just 100)),
            (actorFilter, Nothing, (Nothing, Just 100)),
            (actorFilter, Just (ActivityCursor 1 2 3 4), (Just 1, Just 100))
          ],
      -- An actor that decodes as a credential is matched in BOTH forms, because actor_id holds hex
      -- on the DRep and committee arms and a bech32 stake address on the delegation arm.
      testCase "a bech32 DRep id is matched as itself and as its hex credential" $
        let (_, ps) = activityWhere actorFilter Older Nothing (Nothing, Just 100) in length ps @?= 3,
      testCase "a stake address is matched as itself alone, not rejected" $
        let f = emptyGovActivityFilter {govActivityFilterActors = ["stake_test1uq"]}
            (_, ps) = activityWhere f Older Nothing (Nothing, Just 100)
         in length ps @?= 2,
      testCase "the ladder widens strictly and ends before the unbounded rung" $
        (and (zipWith (<) activityWindows (drop 1 activityWindows)), length activityWindows)
          @?= (True, 3)
    ]
  where
    cursors =
      [ ActivityCursor 0 0 1 0,
        ActivityCursor 136821634 0 4 2,
        ActivityCursor 136689360 13 2 3244711,
        ActivityCursor 1 (-1) 7 42,
        ActivityCursor 1 (-2) 11 42
      ]
    actorFilter =
      emptyGovActivityFilter
        { govActivityFilterActors = ["drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"]
        }

errorCodeTests :: TestTree
errorCodeTests =
  testGroup
    "the error code vocabulary"
    [ -- The code is the contract a client branches on, and it crosses the wire twice: out of a
      -- FromHttpApiData parser as a message, and back in through the error formatter. If the two
      -- spellings ever drift, every parse failure collapses to invalid_parameter and still looks
      -- like a working 400.
      testCase "every code round-trips through its own wire tag" $
        map (errorCodeFromText . jsonTag) codes @?= codes,
      -- servant passes a CAPTURE's parser message through verbatim...
      testCase "a bare code, as a failing capture sends it" $
        map errorCodeFromParserMessage ["invalid_drep_id", "invalid_gov_action_id", "invalid_cursor"]
          @?= [InvalidDrepId, InvalidGovActionId, InvalidCursor],
      -- ...and WRAPS a query parameter's. This is the case that was silently answering
      -- invalid_parameter on /delegations?drep_id= and /treasury-withdrawals?gov_action_id=.
      testCase "a wrapped code, as a failing query parameter sends it" $
        map
          errorCodeFromParserMessage
          [ "Error parsing query parameter drep_id failed: invalid_drep_id",
            "Error parsing query parameter gov_action_id failed: invalid_gov_action_id"
          ]
          @?= [InvalidDrepId, InvalidGovActionId],
      -- A parser that did not return a code of ours still has to produce a valid body.
      testCase "anything else is invalid_parameter" $
        map errorCodeFromParserMessage ["", "could not parse: Int", "boom", ":", "not_a_code"]
          @?= replicate 5 InvalidParameter,
      -- genericErrorMessage is total over the enum; this is what catches a new code added without
      -- one, which would otherwise inherit no wording at all.
      testCase "every code has a non-empty human message" $
        filter (T.null . genericErrorMessage) codes @?= [],
      testCase "no two codes share a message" $
        length (nub (map genericErrorMessage codes)) @?= length codes - 1
    ]
  where
    codes = [minBound .. maxBound] :: [ErrorCode]

voteStageTests :: TestTree
voteStageTests =
  testGroup
    "the votes page's base shape"
    [ -- The whole point of the four-stage page is that a join nobody asked for is not paid for.
      -- MEASURED on preprod's 3.24 M committee vote rows: tx ⋈ block is 8.7 s of a 9.9 s count and
      -- cc_cold_interval is 9.5 s, so a shape that joined them unconditionally is the difference
      -- between 1.09 s and 14.2 s.
      testCase "an unfiltered default page joins nothing but the action" $
        let frm = voteBaseFrom (voteJoinsFor emptyVoteFilter VotesOrderByCastAt)
         in ( T.isInfixOf "public.voting_procedure" frm,
              T.isInfixOf "palmares.gov_action" frm,
              T.isInfixOf "public.block" frm,
              T.isInfixOf "cc_cold_interval" frm,
              T.isInfixOf "drep_epoch_power" frm
            )
              @?= (True, True, False, False, False),
      testCase "a time or epoch bound is what brings in tx and block, and only that" $
        let withTime = voteJoinsFor emptyVoteFilter {voteFilterFromEpoch = Just 315} VotesOrderByCastAt
         in (vjBlock withTime, vjAnchor withTime, vjCold withTime, vjPower withTime)
              @?= (True, False, False, False),
      testCase "the latency sort needs block; the voter_id sort needs the cold key" $
        ( vjBlock (voteJoinsFor emptyVoteFilter VotesOrderByLatency),
          vjCold (voteJoinsFor emptyVoteFilter VotesOrderByVoterId),
          vjPower (voteJoinsFor emptyVoteFilter VotesOrderByVotingPower)
        )
          @?= (True, True, True),
      testCase "anchor_status brings in the anchor, q brings in the drep" $
        ( vjAnchor (voteJoinsFor emptyVoteFilter {voteFilterAnchorStatus = [AnchorValid]} VotesOrderByCastAt),
          vjDRep (voteJoinsFor emptyVoteFilter {voteFilterQ = Just "abc"} VotesOrderByCastAt)
        )
          @?= (True, True),
      -- The default sort orders by voting_procedure.id, which is the fact that removes tx ⋈ block
      -- from every ordinary page. Verified against the chain: the top 50 by id DESC and the top 50
      -- by (block.time DESC, id DESC) are the same 50 rows.
      testCase "the default sort is the primary key, not a block time" $
        let SortSpec col _ tie = voteBaseSortSpec VotesOrderByCastAt
         in (col, tie) @?= ("v.id", "v.id"),
      -- postgresql-simple counts placeholders lexically and complains only at run time, and the
      -- voter clause binds the same list FOUR times — once per credential table.
      testCase "every filter shape binds as many values as it has placeholders" $
        mapM_
          ( \f ->
              let (sql, ps) = voteBaseWhere f
               in assertEqual (T.unpack sql) (T.count "?" sql) (length ps)
          )
          [ emptyVoteFilter,
            emptyVoteFilter {voteFilterVoterIds = ["aa", "bb"]},
            emptyVoteFilter {voteFilterRoles = [DRep, SPO]},
            emptyVoteFilter {voteFilterAnchorStatus = [AnchorValid], voteFilterQ = Just "x"},
            emptyVoteFilter
              { voteFilterVoterIds = ["aa"],
                voteFilterRoles = [ConstitutionalCommittee],
                voteFilterFromEpoch = Just 300,
                voteFilterToEpoch = Just 320,
                voteFilterQ = Just "y"
              }
          ],
      -- A voter id must be matched against all four credential sources, and the committee needs
      -- two of them: a cold id matches its own committee_hash row AND every hot key registered to
      -- it, because a vote is signed by the hot key and published under the cold one (D-24).
      testCase "a voter id is matched against drep, pool, and the committee's cold AND hot keys" $
        let (sql, ps) = voteBaseWhere emptyVoteFilter {voteFilterVoterIds = ["aa"]}
         in ( T.isInfixOf "drep_hash" sql,
              T.isInfixOf "pool_hash" sql,
              T.isInfixOf "committee_hash" sql,
              T.isInfixOf "committee_registration" sql,
              length ps
            )
              @?= (True, True, True, True, 4),
      -- And it must do that WITHOUT the interval join, which is the 9.5 s this rewrite removes.
      testCase "the voter filter does not reach for cc_cold_interval" $
        T.isInfixOf "cc_cold_interval" (fst (voteBaseWhere emptyVoteFilter {voteFilterVoterIds = ["aa"]}))
          @?= False,
      -- ---- the third DRep status (owner decision 2026-10-21) --------------------------------
      --
      -- `palmares.drep` computes is_active as COALESCE(active_until >= tip, false), so a DRep with
      -- NO ledger deadline at all falls out as false and is indistinguishable from one whose
      -- deadline has passed. Measured on preprod at epoch 320: 90 of 294 registered DReps have
      -- never had a drep_distr row, and Koios calls 21 of those 90 ACTIVE. So the arm ORDER is the
      -- correctness property, not a style choice: test the null deadline first or publish a false
      -- claim about 21 real actors. This asserts the order rather than the whole string, because
      -- the string is allowed to be reformatted and the order is not.
      testCase "the status expression tests the unknown deadline BEFORE is_active" $
        let unknownAt = T.length (fst (T.breakOn "active_until_epoch IS NULL" drepStatusExpr))
            activeAt = T.length (fst (T.breakOn "d.is_active" drepStatusExpr))
         in ( T.isInfixOf "active_until_epoch IS NULL" drepStatusExpr,
              T.isInfixOf "'unknown'" drepStatusExpr,
              unknownAt < activeAt
            )
              @?= (True, True, True),
      -- `unknown` must be in the DEFAULT set. Those 90 DReps were on the default page before,
      -- labelled `inactive`; leaving the new value out of the default would drop 90 registered
      -- DReps off the page in order to stop mislabelling 21 of them. With it in, the change is a
      -- pure relabel and the page's population is unchanged.
      --
      -- __And the Koios parity gate now rides on this.__ `GV-02`: the reconciler used to fetch our
      -- side with an explicit `?status=active&status=inactive`, which left those 90 out and made the
      -- nightly gate report 90 false `membership` divergences. It fetches `/dreps` with no filter
      -- now, so THIS set is what our side of the comparison is. Narrowing the default would make the
      -- gate lie again, silently, from a file in another directory — which is why the dependency is
      -- written down here rather than inferred.
      testCase "the default status set includes unknown, so the default population is unchanged" $
        (effectiveDRepStatus emptyDRepFilter, length (effectiveDRepStatus emptyDRepFilter))
          @?= ([DRepActive, DRepInactive, DRepUnknown], 3),
      -- An explicit filter still wins over the default, including for the new value alone.
      testCase "an explicit status filter overrides the default" $
        effectiveDRepStatus emptyDRepFilter {drepFilterStatus = [DRepUnknown]} @?= [DRepUnknown],
      -- The facet universe is every value `drepStatusExpr` can produce and no others. `reserved` is
      -- not one of them: the two reserved ledger options have no drep_registration row and never
      -- enter /dreps at all, so a facet count for them could only ever be zero.
      testCase "the facet universe is the four registered statuses, reserved excluded" $
        (registeredDRepStatuses, DRepReserved `elem` registeredDRepStatuses)
          @?= ([DRepActive, DRepInactive, DRepUnknown, DRepRetired], False),
      -- The second copy of the CASE is gone. `drepStatusExpr` exists so that the projection, the
      -- filter, the facet and the palette cannot disagree about what `status` means — and the
      -- palette statement held a verbatim duplicate, which is how it would have kept answering
      -- `inactive` after the projection beside it started answering `unknown`.
      testCase "the palette statement interpolates the status expression instead of copying it" $
        ( T.isInfixOf drepStatusExpr searchSql,
          T.count "WHEN d.is_active" searchSql
        )
          @?= (True, 1)
    ]

------------------------------------------------------------------------------------------------

-- * The credential lookup's three roles (ADR 0006)

------------------------------------------------------------------------------------------------

-- | 28 bytes, the shape every governance credential's hash has. The SAME bytes are rendered under
-- all three roles below, which is the whole point: the role is in the header byte and nowhere else,
-- so a codec that dropped it would make these identifiers equal and every assertion vacuous.
credentialRaw :: ByteString
credentialRaw = BS.replicate 28 0x7a

credentialRoleTests :: TestTree
credentialRoleTests =
  testGroup
    "/profiles/by-credential accepts every claimable role"
    [ -- The measured defect: the lookup went through `parseDrepIdAny`, whose HRP table is `drep`
      -- alone, so a committee credential the registry already held a claim for was answered
      -- `400 invalid_drep_id` — "Not a DRep identifier", which is true of the input and useless to
      -- the caller. ADR 0006 settles that all three roles are claimable and the write side has
      -- always accepted all three.
      testCase "all three roles canonicalise to themselves, in key and script form" $
        map canonicalGovCredential allSix @?= map Just allSix,
      -- Six DIFFERENT identifiers over ONE hash. If any pair collided the test above would pass
      -- while the lookup matched the wrong profile.
      testCase "the six renderings of one hash are six distinct identifiers" $
        length (nub allSix) @?= 6,
      -- Unchanged, and the reason is unchanged: neither carries a header byte, and `drep` is the
      -- HRP for both credential kinds, so accepting one would mean choosing a byte — and choosing
      -- the key byte reports every script credential as a key credential.
      testCase "CIP-105 and 56 bare hex characters are still REFUSED" $
        map canonicalGovCredential [drepIdCip105 credentialRaw, T.replicate 56 "a"]
          @?= [Nothing, Nothing],
      testCase "garbage is refused" $
        map canonicalGovCredential ["", "drep_always_abstain", "pool1xyz", "cc_cold1xyz"]
          @?= replicate 4 Nothing,
      -- All-upper-case is a VALID bech32 spelling of the same id (BIP-173 forbids only mixed
      -- case), and going through the parse and back out is what makes it match a stored
      -- lower-case one. Asserted for a COMMITTEE id, because that is the half that was unreachable.
      testCase "an upper-case committee spelling canonicalises to the stored lower-case form" $
        canonicalGovCredential (T.toUpper (ccColdIdCip129 False credentialRaw))
          @?= Just (ccColdIdCip129 False credentialRaw),
      -- This was the silent half of the same bug: over `parseDrepIdAny` a committee claim's
      -- `credential_is_script` was published as null — "unknown" — which is the one field
      -- `AttestProfileRow` promises a verification UI will never have to guess.
      testCase "credentialIsScript reads the header byte for all three roles" $
        map credentialIsScript allSix
          @?= [Just False, Just True, Just False, Just True, Just False, Just True],
      testCase "and still never guesses for an identifier that carries no header byte" $
        map credentialIsScript [drepIdCip105 credentialRaw, "not a credential"] @?= [Nothing, Nothing]
    ]
  where
    allSix =
      [ drepIdCip129 False credentialRaw,
        drepIdCip129 True credentialRaw,
        ccColdIdCip129 False credentialRaw,
        ccColdIdCip129 True credentialRaw,
        ccHotIdCip129 False credentialRaw,
        ccHotIdCip129 True credentialRaw
      ]

------------------------------------------------------------------------------------------------

-- * The wallet lookup: a CIP-68 user token's profile

------------------------------------------------------------------------------------------------

-- | The deployed minting policy, and a 28-byte name body. The two asset classes below differ in
-- their four-byte CIP-67 label and in nothing else, which is the entire derivation.
profilePolicy, nameBody, userTokenAc, refTokenAc :: T.Text
profilePolicy = "648c6a732aa55efec29815bdd25cf65c565cf92619aadde1d31496d3"
nameBody = T.replicate 56 "a"
userTokenAc = profilePolicy <> ".000de140" <> nameBody
refTokenAc = profilePolicy <> ".000643b0" <> nameBody

-- | @refTokenAc@ through Atlas's own codec — the one the @{profile-id}@ capture uses.
parsedRefToken :: Maybe ProfileRefAC
parsedRefToken = either (const Nothing) Just (parseUrlPiece refTokenAc)

userTokenTests :: TestTree
userTokenTests =
  testGroup
    "/profiles/by-user-token derives the reference id a wallet cannot"
    [ -- Guards the whole group: if the right-hand side were Nothing, the first case below would
      -- pass by comparing two Nothings and prove nothing at all.
      testCase "the expected reference asset class really parses" $
        assertBool "refTokenAc did not parse through Atlas's codec" (parsedRefToken /= Nothing),
      testCase "a user token resolves to its reference half" $
        profileRefOfUserToken userTokenAc @?= parsedRefToken,
      -- Hex is case-insensitive and Atlas renders it lower-case, so a wallet that hands back an
      -- upper-case spelling must still find its profile rather than a 400.
      testCase "upper-case hex and surrounding space are accepted" $
        map profileRefOfUserToken ["  " <> T.toUpper userTokenAc <> "  ", T.toUpper userTokenAc]
          @?= [parsedRefToken, parsedRefToken],
      -- THE FOUR REFUSALS, and they are refusals rather than empty results on purpose: "no
      -- profile" for an identifier that could not name one reads as "you own no profile".
      --
      -- The reference token is the interesting one. It is a perfectly good asset class and it IS a
      -- profile id, so a lenient derivation would have answered the right profile for the wrong
      -- reason and taught a client that either half works — which breaks the moment the two labels
      -- are the only thing telling a wallet's token from the registry's.
      testCase "the reference half, an attestation id, a dispute id and lovelace are all refused" $
        map
          profileRefOfUserToken
          [ refTokenAc,
            profilePolicy <> ".00001070" <> nameBody,
            profilePolicy <> ".000020e0" <> nameBody,
            "lovelace"
          ]
          @?= replicate 4 Nothing,
      testCase "so is anything that is not <policy>.<name>" $
        map profileRefOfUserToken ["", ".", profilePolicy, profilePolicy <> ".000de140" <> nameBody <> ".x"]
          @?= replicate 4 Nothing,
      -- The two labels are copied into "Query.Attest" rather than imported, because importing them
      -- would put `plutus-ledger-api` on a public read path (query-api's cabal stanza says so in a
      -- comment). This is the price of that copy: the labels are pinned to CIP-67's published
      -- values, so a divergence from `Palmares.Onchain.CIP68` fails here rather than returning
      -- somebody else's profile.
      testCase "the two CIP-67 labels are the published ones, 100 and 222" $
        (T.take 8 (T.drop 57 refTokenAc), T.take 8 (T.drop 57 userTokenAc))
          @?= ("000643b0", "000de140")
    ]

------------------------------------------------------------------------------------------------

-- * issuer= is an issuance history, so an unconsented withdrawal is not in it

------------------------------------------------------------------------------------------------

issuerAttributionTests :: TestTree
issuerAttributionTests =
  testGroup
    "issuer= excludes an unaccepted credential_withdrawal"
    [ -- `Mf` — spend the issuer's user NFT — is CONDITIONAL, and `CredentialWithdrawal` is its one
      -- exemption (ADR 0003), deliberately: the case a withdrawal exists for is a profile that
      -- claimed somebody else's credential, and that profile's token is held by whoever did it. So
      -- a withdrawal is minted on the named CREDENTIAL's proof alone, while `Mc1` forces its
      -- `issuer` to equal its `subject` — the minting policy's own comment says that makes `issuer`
      -- structural and "makes no claim about who acted". The read layer was serving it as the
      -- named profile's issuance anyway, and the chain cannot be changed (frozen hashes), so the
      -- clause lives here.
      testCase "the issuer clause carries the kind guard, bound not spliced" $
        let (sql, ps) = attestationWhere emptyAttestationRecordFilter {attestationRecordFilterIssuer = issuer}
         in ( T.isInfixOf "issuer_profile_id = ?" sql,
              T.isInfixOf "attestation_kind = ?" sql,
              T.isInfixOf "is_accepted = false" sql,
              T.count "?" sql == length ps,
              length ps
            )
              @?= (True, True, True, True, 2),
      -- The SUBJECT direction must NOT be narrowed: on a credential record the subject is the
      -- profile the record is about, which is exactly where a withdrawal belongs. Narrowing both
      -- would make an unaccepted withdrawal invisible, and ADR 0003's rule is that nothing is ever
      -- hidden or deleted.
      testCase "the subject clause is a plain equality, with no guard" $
        let (sql, ps) = attestationWhere emptyAttestationRecordFilter {attestationRecordFilterSubject = issuer}
         in (T.isInfixOf "subject_profile_id = ?" sql, T.isInfixOf "attestation_kind" sql, length ps)
              @?= (True, False, 1),
      -- postgresql-simple counts placeholders lexically and complains only at run time, with a
      -- count rather than a name. Same check every other *Where in this suite carries.
      testCase "every filter shape binds as many values as it has placeholders" $
        mapM_
          ( \f ->
              let (sql, ps) = attestationWhere f
               in assertEqual (T.unpack sql) (T.count "?" sql) (length ps)
          )
          [ emptyAttestationRecordFilter,
            emptyAttestationRecordFilter {attestationRecordFilterIssuer = issuer},
            emptyAttestationRecordFilter {attestationRecordFilterSubject = issuer, attestationRecordFilterIssuer = issuer},
            emptyAttestationRecordFilter {attestationRecordFilterKinds = [CredentialClaim, CredentialWithdrawal]},
            emptyAttestationRecordFilter {attestationRecordFilterAccepted = Just True},
            emptyAttestationRecordFilter
              { attestationRecordFilterIssuer = issuer,
                attestationRecordFilterKinds = [Endorsement],
                attestationRecordFilterAccepted = Just False
              }
          ]
    ]
  where
    issuer = parsedRefToken

------------------------------------------------------------------------------------------------

-- * x-nullable

------------------------------------------------------------------------------------------------

nullabilityTests :: TestTree
nullabilityTests =
  testGroup
    "markNullableFields publishes every Maybe field as nullable"
    [ -- swagger2 omits a record field from `required` exactly when its type is `Maybe a`, so
      -- "absent from required" IS the Maybe and this pass copies that distinction into the one key
      -- a client codegen reads. Both directions, because a pass that marked everything would
      -- satisfy the first half alone.
      testCase "an optional scalar gains the key and a required one does not" $
        let out = markNullableFields oneSchema
         in ( nullableAt out ["definitions", "Row", "properties", "maybe_field"],
              nullableAt out ["definitions", "Row", "properties", "required_field"]
            )
              @?= (Just (Bool True), Nothing),
      -- 15 of the 127 are a bare $ref. The key is written beside the reference, which a strict
      -- Swagger 2.0 reader may ignore — stated in the document itself rather than papered over —
      -- and the $ref must survive untouched either way.
      testCase "a $ref property keeps its reference and gains the key beside it" $
        let out = markNullableFields oneSchema
         in ( nullableAt out ["definitions", "Row", "properties", "maybe_object"],
              refAt out ["definitions", "Row", "properties", "maybe_object"]
            )
              @?= (Just (Bool True), Just (String "#/definitions/Other")),
      -- The `type: "object"` guard. Without it, a DTO with a field NAMED `properties` would be
      -- read as schema structure and every sibling field marked nullable — this is the case that
      -- makes the guard load-bearing rather than decorative.
      testCase "a DTO field named properties is data, not structure" $
        let out = markNullableFields trapSchema
         in ( nullableAt out ["definitions", "Trap", "properties", "properties"],
              nullableAt out ["definitions", "Trap", "properties", "sibling"]
            )
              @?= (Just (Bool True), Nothing),
      -- An enum definition has no `properties` at all and must come back byte-identical: the pass
      -- must never be the thing that invents a schema.
      testCase "a schema with no properties is returned unchanged" $
        markNullableFields enumSchema @?= enumSchema,
      -- Idempotent, because the document is regenerated on every boot and re-running a pass over
      -- its own output is the cheapest thing that can go wrong.
      testCase "running it twice changes nothing the first run did not" $
        markNullableFields (markNullableFields oneSchema) @?= markNullableFields oneSchema
    ]
  where
    oneSchema =
      Aeson.object
        [ "definitions"
            Aeson..= Aeson.object
              [ "Row"
                  Aeson..= Aeson.object
                    [ "type" Aeson..= String "object",
                      "required" Aeson..= [String "required_field"],
                      "properties"
                        Aeson..= Aeson.object
                          [ "required_field" Aeson..= Aeson.object ["type" Aeson..= String "string"],
                            "maybe_field" Aeson..= Aeson.object ["type" Aeson..= String "integer"],
                            "maybe_object" Aeson..= Aeson.object ["$ref" Aeson..= String "#/definitions/Other"]
                          ]
                    ]
              ]
        ]
    trapSchema =
      Aeson.object
        [ "definitions"
            Aeson..= Aeson.object
              [ "Trap"
                  Aeson..= Aeson.object
                    [ "type" Aeson..= String "object",
                      "required" Aeson..= [String "sibling"],
                      "properties"
                        Aeson..= Aeson.object
                          [ "sibling" Aeson..= Aeson.object ["type" Aeson..= String "string"],
                            "properties" Aeson..= Aeson.object ["type" Aeson..= String "string"]
                          ]
                    ]
              ]
        ]
    enumSchema =
      Aeson.object
        [ "definitions"
            Aeson..= Aeson.object
              [ "Verdict"
                  Aeson..= Aeson.object
                    [ "type" Aeson..= String "string",
                      "enum" Aeson..= [String "upheld", String "rejected", String "expired"]
                    ]
              ]
        ]

-- | Follow a path of object keys, then read @x-nullable@ off whatever is there.
nullableAt :: Value -> [T.Text] -> Maybe Value
nullableAt v path = at' v (path <> ["x-nullable"])

-- | The same, for @$ref@ — so a case can assert that the reference survived the pass.
refAt :: Value -> [T.Text] -> Maybe Value
refAt v path = at' v (path <> ["$ref"])

at' :: Value -> [T.Text] -> Maybe Value
at' v [] = Just v
at' (Object o) (k : ks) = KM.lookup (Key.fromText k) o >>= \v -> at' v ks
at' _ _ = Nothing

------------------------------------------------------------------------------------------------

-- * The refusals servant's router produces

------------------------------------------------------------------------------------------------

refusalTests :: TestTree
refusalTests =
  testGroup
    "405 and 406 carry the documented body"
    [ -- Measured against the deployed binary before the middleware: POST /dreps answered 405 and
      -- GET /profiles with `Accept: text/csv` answered 406, each with ZERO bytes and no content
      -- type — so a browser client doing res.json() on a failure path threw a parse error instead
      -- of reading a code. Neither is reachable through `ErrorFormatters`: servant's router decides
      -- both before a handler exists and offers no formatter hook for either.
      testCase "an empty 405 becomes {code: method_not_allowed}" $ do
        res <- through (responseLBS methodNotAllowed405 [] "")
        body <- bodyOf res
        (statusCode (responseStatus res), lookup hContentType (responseHeaders res), body)
          @?= (405, Just "application/json", encode (ApiError MethodNotAllowed (genericErrorMessage MethodNotAllowed))),
      testCase "an empty 406 becomes {code: not_acceptable}" $ do
        res <- through (responseLBS notAcceptable406 [] "")
        body <- bodyOf res
        (statusCode (responseStatus res), body)
          @?= (406, encode (ApiError NotAcceptable (genericErrorMessage NotAcceptable))),
      -- THE ABSENCE OF A CONTENT TYPE IS THE TEST, not the status. A handler's own 4xx goes through
      -- `mkServantErr`, which sets application/json, so rewriting only the content-type-less
      -- responses cannot touch a body a handler built — which a bare `status == 405` test could.
      testCase "a 405 that already carries a body is left exactly as it was" $ do
        let mine = responseLBS methodNotAllowed405 [(hContentType, "application/json")] "{\"code\":\"mine\"}"
        res <- through mine
        body <- bodyOf res
        body @?= "{\"code\":\"mine\"}",
      testCase "a success is untouched" $ do
        res <- through (responseLBS ok200 [(hContentType, "application/json")] "{\"items\":[]}")
        body <- bodyOf res
        (statusCode (responseStatus res), body) @?= (200, "{\"items\":[]}"),
      -- The statuses the two codes are served with, which is what the Swagger document declares
      -- and what `mkServantErrBody` has to have an arm for: without one it would have fallen
      -- through to err500 and served a 405 as a 500.
      testCase "the two router codes map to 405 and 406" $
        map errorCodeToHttpStatus [MethodNotAllowed, NotAcceptable] @?= [405, 406],
      testCase "and invalid_credential is a 400, like the rest of its group" $
        errorCodeToHttpStatus InvalidCredential @?= 400
    ]
  where
    -- Run the middleware over an application that answers exactly this response, and hand back
    -- whatever reached the responder. `ResponseReceived` has no public constructor outside
    -- Network.Wai.Internal, which is why that module is imported here and nowhere else.
    through res = do
      ref <- newIORef res
      ResponseReceived <-
        refusedRequestMiddleware
          (\_ k -> k res)
          defaultRequest
          (\r -> writeIORef ref r >> pure ResponseReceived)
      readIORef ref

    bodyOf res = do
      let (_, _, withBody) = responseToStream res
      withBody $ \sb -> do
        acc <- newIORef mempty
        sb (\b -> modifyIORef' acc (<> b)) (pure ())
        toLazyByteString <$> readIORef acc

-- | The level-1 anchor's verdict, over all eight combinations — __ADR 0008__.
--
-- Pure, because the defect was in the DECISION and not in the join: resolving an anchor needs
-- `palmares.gov_action` and `palmares.treasury_withdrawal`, which would mean seeding four db-sync
-- tables to manufacture a withdrawal, and none of that would have caught the line that was wrong.
--
-- __What was wrong.__ The verdict read `resolved` off `actionFound` alone. So an anchor that gives
-- BOTH keys and names a payment nobody made — a real governance action beside an address that
-- action never paid, which is exactly the mistake a client makes pasting from two rows — came back
-- `resolved` with `withdrawal: null`, indistinguishable from an anchor that only ever pointed at an
-- action. A UI would have rendered "this payment happened" about a payment that did not.
--
-- The rule: `resolved` means __what the caller asked__ resolved. An address in the anchor is a
-- question about a withdrawal, and an unanswered question is not a yes.
anchorVerdictTests :: TestTree
anchorVerdictTests =
  testGroup
    "the level-1 anchor's verdict asks what the caller asked"
    [ -- Action-only anchors: the address is absent, so the withdrawal join is not a question and
      -- whatever it found is irrelevant. Both rows of the truth table, so "ignored" is pinned
      -- rather than assumed.
      testCase "an action-only anchor resolves on the action alone" $
        ( anchorStatusOf True False Nothing,
          anchorStatusOf True True Nothing
        )
          @?= (L1Resolved, L1Resolved),
      testCase "an action-only anchor whose action is absent is unresolved" $
        ( anchorStatusOf False False Nothing,
          anchorStatusOf False True Nothing
        )
          @?= (L1Unresolved, L1Unresolved),
      -- THE CASE THAT WAS WRONG. Both keys given, the action real, the pair not.
      testCase "a pair whose action exists and whose withdrawal does not is UNRESOLVED" $
        anchorStatusOf True False (Just addr) @?= L1Unresolved,
      testCase "a pair that resolves is resolved" $
        anchorStatusOf True True (Just addr) @?= L1Resolved,
      -- The two remaining rows. `withdrawalFound` without `actionFound` cannot arise from the
      -- statement — the withdrawal join hangs off the action join — but the function is total and
      -- says so rather than leaving it to the SQL to be the only thing that knows.
      testCase "a pair whose action is absent is unresolved either way" $
        ( anchorStatusOf False False (Just addr),
          anchorStatusOf False True (Just addr)
        )
          @?= (L1Unresolved, L1Unresolved),
      -- A reader should be able to tell the three statuses apart; `malformed` is produced before
      -- any join runs, so it is not this function's to return.
      testCase "the verdict never invents malformed — that is decided before the joins" $
        notElem
          L1Malformed
          [ anchorStatusOf a w ad
            | a <- [True, False],
              w <- [True, False],
              ad <- [Nothing, Just addr]
          ]
          @?= True
    ]
  where
    addr = "stake_test1uppy2gm2hqzkwc80em4mlat73j4jyqvzhclrvsu72g9xg4q2yweet"
