{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Parity against Koios preprod (F1 check 6). Koios is a CHECK, never a source.
--
-- @test\/fixtures\/koios\/@ holds the SINGLE-ID wire fixtures; refresh them with the commands in
-- that directory's README. The multi-id replay snapshot pair is a different set, written by
-- @admin reconcile-koios --dump-snapshots test\/fixtures\/snapshot@; never point the dumper at
-- this directory, it would flatten the pinned counts below.
--
-- __What these tests are for.__ Not "does aeson work" — they pin the three things about Koios's
-- wire that a decoder gets wrong silently: lovelace arrives as a STRING, @withdrawal@ is an array
-- rather than null, and a committee vote is published under the HOT credential while we publish
-- the cold one. Each is asserted against the recording, so a Koios change breaks a named test
-- instead of a number in a report.
--
-- __And they pin the six counts that already agree with our own API__, which is the parity signal
-- the whole block exists to produce. Those numbers are preprod's own; if the chain moves far
-- enough to change them, re-record and update them deliberately.
module UnitTests.Reconcile (reconcileTests) where

import Data.Aeson (FromJSON, eitherDecode, eitherDecodeFileStrict)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (nub, sort)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Palmares.DomainTypes.Core.Types (DRepStatus (..), GovActionType (..), Vote (..), VoterRole (..))
import Palmares.Reconcile
import Palmares.Reconcile.Koios
import Test.Tasty
import Test.Tasty.HUnit

-- | Decode a fixture or fail the case with the parse error.
--
-- @eitherDecodeFileStrict@ and not @decodeFileStrict@: a @Nothing@ says only "it did not parse",
-- and the whole value of a wire fixture is that it tells you WHICH field Koios changed.
load :: (FromJSON a) => FilePath -> IO a
load name = do
  r <- eitherDecodeFileStrict ("test/fixtures/koios/" <> name)
  either (assertFailure . (("test/fixtures/koios/" <> name <> ": ") <>)) pure r

reconcileTests :: TestTree
reconcileTests =
  testGroup
    "Koios preprod parity"
    [ wireTests,
      countTests,
      mappingTests,
      primitiveTests,
      rowTests,
      sampleTests
    ]

-- ---------------------------------------------------------------------------------------------

-- | The three encodings that are wrong silently.
wireTests :: TestTree
wireTests =
  testGroup
    "the wire's traps"
    [ testCase "lovelace decodes from a STRING, at full 64-bit width" $ do
        info <- load @[KoiosDRepInfo] "drep_info.json"
        map (fmap unKoiosLovelace . koiosDRepInfoAmount) info @?= [Just 3923709956713]
        map (fmap unKoiosLovelace . koiosDRepInfoDeposit) info @?= [Just 500000000],
      -- 3,923,709,956,713 exceeds nothing in Int64, but it is well past what a naive Double
      -- round-trips exactly, which is why Koios quotes it and why this asserts the exact value.
      testCase "a quoted amount and a bare number both decode" $
        ( decodeLovelace "\"500000000\"",
          decodeLovelace "500000000",
          decodeLovelace "\"-1\""
        )
          @?= (Just 500000000, Just 500000000, Just (-1)),
      testCase "a fractional amount is refused, not rounded" $
        (decodeLovelace "1.5", decodeLovelace "\"1.5\"", decodeLovelace "\"\"", decodeLovelace "\"x\"")
          @?= (Nothing, Nothing, Nothing, Nothing),
      testCase "withdrawal is an array and is empty on every non-withdrawal action" $ do
        ps <- load @[KoiosProposal] "proposal_list.json"
        let withdrawalActions = [p | p <- ps, koiosProposalType p == "TreasuryWithdrawals"]
            others = [p | p <- ps, koiosProposalType p /= "TreasuryWithdrawals"]
        assertBool "there is at least one withdrawal action to test with" (not (null withdrawalActions))
        -- An action that is not a withdrawal has no beneficiaries...
        concatMap koiosProposalWithdrawals others @?= []
        -- ...and every withdrawal action has at least one.
        assertBool
          "every TreasuryWithdrawals action names a beneficiary"
          (all (not . null . koiosProposalWithdrawals) withdrawalActions),
      -- D-24, from the other side. This is the trap that makes a vote-set comparison return
      -- "nothing in common" when the two indexes agree perfectly.
      testCase "a committee vote is published under the HOT credential" $ do
        m <- load @(M.Map Text [KoiosVoteRow]) "proposal_votes.json"
        let rows = concat (M.elems m)
            cc = [r | r <- rows, koiosVoteRole r == "ConstitutionalCommittee"]
        assertBool "the pinned action has a committee vote" (not (null cc))
        assertBool
          "every committee voter_id is a cc_hot1 id, never cc_cold1"
          (all (T.isPrefixOf "cc_hot1" . koiosVoteVoterId) cc),
      testCase "committee_info is an ARRAY of committees, not one object" $ do
        cs <- load @[KoiosCommittee] "committee_info.json"
        length cs @?= 1
        -- Both credentials and both script flags travel, which is what makes the published
        -- CIP-129 id checkable: the header byte has to come from the same key as the hash.
        let ms = concatMap koiosCommitteeMembers cs
        (all (isJust . koiosMemberHotId) ms, all koiosMemberColdHasScript ms) @?= (True, True)
    ]
  where
    decodeLovelace :: String -> Maybe Int
    decodeLovelace s = case eitherDecode (BL8.pack s) of
      Right v -> Just (fromIntegral (unKoiosLovelace v))
      Left _ -> Nothing

-- ---------------------------------------------------------------------------------------------

-- | The counts that already agree with our own API. Preprod's own numbers.
countTests :: TestTree
countTests =
  testGroup
    "counts that agree with our own index"
    [ testCase "294 registered DReps — the same total /dreps serves" $ do
        rows <- load @[KoiosDRepListRow] "drep_list.json"
        (length rows, all koiosDRepListRegistered rows) @?= (294, True),
      testCase "195 power rows at epoch 319 — the same number check 040 asserts" $ do
        rows <- load @[KoiosPowerRow] "drep_voting_power_history.json"
        (length rows, nub (map koiosPowerEpochNo rows)) @?= (195, [319]),
      testCase "131 proposals, 103 expired, 11 with no lifecycle epoch at all" $ do
        ps <- load @[KoiosProposal] "proposal_list.json"
        let settled p =
              any
                isJust
                [ koiosProposalRatifiedEpoch p,
                  koiosProposalEnactedEpoch p,
                  koiosProposalDroppedEpoch p,
                  koiosProposalExpiredEpoch p
                ]
        ( length ps,
          length (filter (isJust . koiosProposalExpiredEpoch) ps),
          length (filter (not . settled) ps)
          )
          @?= (131, 103, 11),
      -- `expiration` is the voting window's close, set at proposal time, and is NOT one of the
      -- four lifecycle epochs. It is present on settled actions too, which is the distinction
      -- our own `last_votable_epoch` rests on.
      testCase "every proposal carries an expiration, settled or not" $ do
        ps <- load @[KoiosProposal] "proposal_list.json"
        filter (isNothing . koiosProposalExpiration) ps @?= [],
      testCase "all seven action types occur, so no mapping line is speculative" $ do
        ps <- load @[KoiosProposal] "proposal_list.json"
        sort (nub (mapMaybe (koiosActionType . koiosProposalType) ps))
          @?= sort [minBound .. maxBound :: GovActionType],
      testCase "16 votes for the fixture DRep — the same total /votes?voter_id= serves" $ do
        m <- load @(M.Map Text [KoiosDRepVoteRow]) "drep_votes.json"
        (M.size m, length (concat (M.elems m))) @?= (1, 16),
      -- Koios returns the LATEST vote per voter on an action, so a re-voted action yields one row
      -- per voter here where our /votes returns every row and marks one is_final. The recording
      -- pins such an action, and this is what says so.
      testCase "the pinned action's voters are distinct, so Koios collapsed the re-vote" $ do
        m <- load @(M.Map Text [KoiosVoteRow]) "proposal_votes.json"
        let rows = concat (M.elems m)
            ids = map koiosVoteVoterId rows
        (length rows, length (nub ids)) @?= (2, 2),
      testCase "the committee is 3 members at quorum 2/3 — the same /committee serves" $ do
        cs <- load @[KoiosCommittee] "committee_info.json"
        map (\c -> (koiosCommitteeQuorumNumerator c, koiosCommitteeQuorumDenominator c, length (koiosCommitteeMembers c))) cs
          @?= [(2, 3, 3)],
      testCase "the tip is a Conway epoch at or past 320" $ do
        t <- load @[KoiosTip] "tip.json"
        map (\x -> koiosTipEpochNo x >= 320) t @?= [True],
      -- The fixture DRep, field for field against what /drep/{id} publishes. This is the case
      -- that found the deregistration bug: live_delegator_count was 13 against our 12.
      testCase "the fixture DRep agrees field for field, delegator count included" $ do
        [i] <- load @[KoiosDRepInfo] "drep_info.json"
        ( koiosDRepInfoHex i,
          koiosDRepInfoHasScript i,
          koiosDRepInfoExpiresEpochNo i,
          koiosDRepInfoLiveDelegatorCount i,
          koiosDRepStatus (koiosDRepInfoStatus i) (koiosDRepInfoActive i)
          )
          @?= ( "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8",
                False,
                Just 333,
                13,
                Just DRepActive
              )
    ]

-- ---------------------------------------------------------------------------------------------

-- | The mappings into our own vocabulary. Total, and an unknown value is a finding.
mappingTests :: TestTree
mappingTests =
  testGroup
    "into our vocabulary"
    [ testCase "every action type maps, and an unknown one does not" $
        ( mapMaybe koiosActionType ["ParameterChange", "InfoAction", "TreasuryWithdrawals"],
          koiosActionType "ParameterChanges",
          koiosActionType "parameter_change"
        )
          @?= ([ParameterChange, InfoAction, TreasuryWithdrawals], Nothing, Nothing),
      -- The spellings happen to equal our constructor names. That is a coincidence of two
      -- independent choices, and this asserts it rather than relying on it.
      testCase "the seven Koios spellings are exactly our seven constructors" $
        mapMaybe koiosActionType (map (T.pack . show) ([minBound .. maxBound] :: [GovActionType]))
          @?= [minBound .. maxBound],
      -- TWO inputs, because Koios splits what we join: it says `registered` for a lapsed DRep and
      -- marks the lapse in `active`. Reading drep_status alone reports every lapsed DRep active.
      testCase "drep_status needs `active` to tell active from inactive" $
        ( koiosDRepStatus "registered" True,
          koiosDRepStatus "registered" False,
          koiosDRepStatus "retired" True,
          koiosDRepStatus "something_new" True
        )
          @?= (Just DRepActive, Just DRepInactive, Just DRepRetired, Nothing),
      testCase "the three verdicts map, and lowercase does not" $
        (mapMaybe koiosVote ["Yes", "No", "Abstain"], koiosVote "yes")
          @?= ([Yes, No, Abstain], Nothing),
      -- SPO, not StakePool, and not our own wire form `spo`. Three vocabularies, one mapping.
      testCase "the three roles map from Koios's spellings, not from ours" $
        ( mapMaybe koiosVoterRole ["DRep", "SPO", "ConstitutionalCommittee"],
          koiosVoterRole "spo",
          koiosVoterRole "drep"
        )
          @?= ([DRep, SPO, ConstitutionalCommittee], Nothing, Nothing),
      -- Every vote and role in the recording must map, or the reconciler would silently drop rows.
      testCase "every verdict and role in the recording maps" $ do
        m <- load @(M.Map Text [KoiosVoteRow]) "proposal_votes.json"
        d <- load @(M.Map Text [KoiosDRepVoteRow]) "drep_votes.json"
        let rows = concat (M.elems m)
            dRows = concat (M.elems d)
        ( filter (isNothing . koiosVote . koiosVoteVote) rows,
          filter (isNothing . koiosVoterRole . koiosVoteRole) rows,
          length (filter (isNothing . koiosVote . koiosDRepVoteVote) dRows)
          )
          @?= ([], [], 0)
    ]

-- ---------------------------------------------------------------------------------------------

-- | The comparison primitive, the waiver file, the freshness guard and the report.
--
-- No fixtures and no database: these are the decisions the reconciliation rests on, and every one
-- of them is a place where a wrong answer looks exactly like a right one. A waiver that explains
-- the wrong row, a freshness guard that lets a two-epoch skew through, a report that calls an
-- aborted run a pass — none of those fail loudly on their own.
primitiveTests :: TestTree
primitiveTests =
  testGroup
    "Reconcile primitives"
    [ testCase "diffKeyed reports a one-sided key as a membership divergence, in key order" $
        let k = M.fromList [("a", 1 :: Int), ("b", 2)]
            p = M.fromList [("b", 2 :: Int), ("c", 3)]
         in map quad (diffKeyed id amountDiff k p)
              @?= [ ("a", "membership", "present", "absent"),
                    ("c", "membership", "absent", "present")
                  ],
      -- The comparator returns only what differs. If it returned every field and the primitive
      -- filtered, every comparator would carry the same filter and one would carry it wrongly.
      testCase "diffKeyed reports only the fields the comparator returns" $
        let k = M.fromList [("a", 10 :: Int)]
            p = M.fromList [("a", 11 :: Int)]
         in map triple (diffKeyed id amountDiff k p) @?= [("amount", "10", "11")],
      testCase "a key on both sides with nothing different yields no divergence" $
        let m = M.fromList [("a", 7 :: Int), ("b", 8)]
         in diffKeyed id amountDiff m m @?= [],
      -- The same key means different things in different rows: a DRep id is a membership key in R1
      -- and a profile key in R2, so a waiver for one is not a waiver for the other.
      testCase "an exception on (row, key, field) explains that divergence and nothing else" $
        let d1 = Divergence "a" "amount" "10" "11"
            d2 = Divergence "b" "amount" "10" "11"
            e = entry R3 "a" (Just "amount") "known"
         in ( applyExceptions [e] R3 [d1, d2],
              applyExceptions [e] R5 [d1, d2]
            )
              @?= (([d2], [d1]), ([d1, d2], [])),
      testCase "an exception with no field explains every field of that key" $
        let d = Divergence "a" "delegator_count" "13" "12"
         in applyExceptions [entry R2 "a" Nothing "known"] R2 [d] @?= ([], [d]),
      testCase "an exception that matched nothing is reported stale" $
        let e = entry R9 "gone" Nothing "stale"
         in staleExceptions [e] [mkRow [] R9 7 []] @?= [e],
      -- A skipped row compared nothing, so nothing in it could have matched. A run that aborted
      -- must not propose deleting the waivers it never reached.
      testCase "a skipped row does not make its exceptions stale" $
        let e = entry R9 "gone" Nothing "unreached"
         in staleExceptions [e] [skippedRow R9 "epoch skew"] @?= [e],
      testCase "an exception that explained something is not stale" $
        let d = Divergence "a" "amount" "10" "11"
            e = entry R3 "a" Nothing "known"
         in staleExceptions [e] [mkRow [e] R3 1 [d]] @?= [],
      -- An epoch skew of ONE is two indexes on either side of a boundary, seconds apart. Two is a
      -- whole epoch of votes, power and lifecycle transitions.
      testCase "freshness aborts on epoch skew > 1 or lag over the bound, and only then" $
        ( checkFreshness 320 320 41 300,
          checkFreshness 320 321 41 300,
          checkFreshness 321 320 41 300,
          checkFreshness 318 320 41 300,
          checkFreshness 320 320 412 300
        )
          @?= ( Fresh,
                Fresh,
                Fresh,
                Aborted "epoch skew 2 > 1 (ours 318, koios 320)",
                Aborted "lag 412s > 300s"
              ),
      testCase "exit code: 0 clean or explained, 1 unexplained, 3 aborted" $
        let t = UTCTime (fromGregorian 2026 10 20) 0
            d = Divergence "a" "membership" "present" "absent"
            e = entry R1 "a" Nothing "known"
            ok = mkReport "preprod" t 320 41 320 [] [mkRow [] R1 294 []]
            waived = mkReport "preprod" t 320 41 320 [e] [mkRow [e] R1 294 [d]]
            bad = mkReport "preprod" t 320 41 320 [] [mkRow [] R1 294 [d]]
            skew = "epoch skew 2 > 1 (ours 318, koios 320)"
            aborted =
              mkReport
                "preprod"
                t
                318
                41
                320
                []
                [ mkRow [] R10 1 [Divergence "freshness" "epoch_skew" "320" "318"],
                  skippedRow R1 skew
                ]
         in ( (reportStatus ok, reportUnexplained ok, reportExitCode ok),
              (reportStatus waived, reportUnexplained waived, reportExitCode waived),
              (reportStatus bad, reportUnexplained bad, reportExitCode bad),
              (reportStatus aborted, reportExitCode aborted)
            )
              @?= ( (ReportOk, 0, 0),
                    (ReportOk, 0, 0),
                    (ReportDivergent, 1, 1),
                    (ReportAborted, 3)
                  ),
      -- A skipped row aborts the whole report even when every other row is clean: a run that did
      -- not compare R3 has not checked R3, and "ok" with R3 missing is a false pass.
      testCase "one skipped row aborts a report whose other rows are all clean" $
        let t = UTCTime (fromGregorian 2026 10 20) 0
            r = mkReport "preprod" t 320 41 320 [] [mkRow [] R1 294 [], skippedRow R2 "no snapshot"]
         in (reportStatus r, reportUnexplained r, reportExitCode r) @?= (ReportAborted, 0, 3),
      -- 2 is reserved for transport failure and is produced by the executable, never here.
      testCase "no report ever yields exit code 2" $
        let t = UTCTime (fromGregorian 2026 10 20) 0
            d = Divergence "a" "membership" "present" "absent"
            rs =
              [ mkReport "preprod" t 320 41 320 [] [mkRow [] R1 1 []],
                mkReport "preprod" t 320 41 320 [] [mkRow [] R1 1 [d]],
                mkReport "preprod" t 320 41 320 [] [skippedRow R1 "why"]
              ]
         in (filter (== 2) (map reportExitCode rs), sort (map reportExitCode rs)) @?= ([], [0, 1, 3]),
      testCase "row ids round-trip through the spelling the waiver file uses" $
        map rowIdText [minBound .. maxBound]
          @?= ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10"],
      testCase "the committed waiver file parses, and every entry carries reason/opened/owner" $ do
        es <- loadExceptions "config/reconcile-exceptions.yaml" >>= either assertFailure pure
        ( all (not . T.null . exceptionReason) es,
          all (not . T.null . exceptionOwner) es
          )
          @?= (True, True),
      testCase "a missing waiver file is a Left, not an empty list" $ do
        r <- loadExceptions "config/does-not-exist.yaml"
        case r of
          Left _ -> pure ()
          Right _ -> assertFailure "a missing waiver file must not read as zero exceptions"
    ]
  where
    quad d = (divergenceKey d, divergenceField d, divergenceKoios d, divergencePalmares d)
    triple d = (divergenceField d, divergenceKoios d, divergencePalmares d)
    amountDiff x y = [("amount", tshow x, tshow y) | x /= y]
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show
    entry r k f reason = ExceptionEntry r k f reason (fromGregorian 2026 10 20) "it@blazarlabs.io"

-- ---------------------------------------------------------------------------------------------

-- | The ten rows, over a hand-built pair.
--
-- No recording and no database: the pair is the smallest consistent pair of readings — two DReps,
-- both reserved ledger options, one action, one committee member, one withdrawal, one vote — and
-- each case applies ONE mutation to it. That is the only way to test a row in isolation: against a
-- recording, a row either agrees (proving nothing about the comparison) or disagrees for reasons
-- the test did not choose.
--
-- The mutators are plain record updates HERE, not library code. A library function that breaks a
-- snapshot on purpose is a function someone will eventually call by accident.
rowTests :: TestTree
rowTests =
  testGroup
    "Reconcile rows"
    [ testCase "a consistent snapshot pair yields all ten rows ok" $ do
        let rs = reconcileAll kOk pOk []
        map rowId rs @?= [R1, R2, R3, R4, R5, R6, R7, R8, R9, R10]
        map rowStatus rs @?= replicate 10 RowOk
        sum (map (length . rowUnexplained) rs) @?= 0,
      -- Every row must actually have compared something. A row that silently compared zero keys
      -- would pass on any pair at all, which is the failure mode a hand-built fixture invites.
      testCase "every row compared at least one key" $
        filter ((== 0) . rowCompared) (reconcileAll kOk pOk []) @?= [],
      testCase "R1: a DRep Koios has and we do not is one membership divergence" $ do
        let r1 = row R1 (reconcileAll kOk (dropDRep dB pOk) [])
        (rowStatus r1, rowUnexplained r1)
          @?= (RowDivergent, [Divergence dB "membership" "present" "absent"]),
      testCase "R2: expires_epoch_no is compared against active_until_epoch" $
        rowUnexplained (row R2 (reconcileAll kOk (setActiveUntil dA 334 pOk) []))
          @?= [Divergence dA "active_until_epoch" "Just 333" "Just 334"],
      -- Koios splits what we join, so this is the case that would pass if koiosDRepStatus read
      -- drep_status alone: `registered` + active=False is our `inactive`, not our `active`.
      testCase "R2: a lapsed registration is inactive, not active" $
        rowUnexplained (row R2 (reconcileAll (setKoiosActive dA False kOk) pOk []))
          @?= [Divergence dA "status" "Just DRepInactive" "Just DRepActive"],
      testCase "R2: the delegator count is compared, which is how the live_delegation bug surfaced" $
        rowUnexplained (row R2 (reconcileAll kOk (setDelegators dA 12 pOk) []))
          @?= [Divergence dA "delegator_count" "13" "12"],
      testCase "R3: voting power is exact lovelace, keyed by (drep_id, epoch)" $
        rowUnexplained (row R3 (reconcileAll kOk (setPower dA 319 3923709956712 pOk) []))
          @?= [Divergence (dA <> ":319") "lovelace" "3923709956713" "3923709956712"],
      -- D-20: the reserved options are rows like any other, and they hold most of the power. A
      -- snapshot that filtered them would understate the total by about half.
      testCase "R4: the per-epoch total includes BOTH reserved ledger options" $ do
        let r4 = row R4 (reconcileAll kOk (dropPower abstainId 319 pOk) [])
        -- 3,923,709,956,713 + 830,756,067,101 + 431,863,790,957,959 + 325,390,800,383, against the
        -- same sum without always_abstain. The option holds 98.8% of this fixture's power, which is
        -- the point: a snapshot that filtered the reserved options would not be slightly wrong.
        (rowStatus r4, rowUnexplained r4)
          @?= ( RowDivergent,
                [Divergence "319" "total_lovelace" "436943647782156" "5079856824197"]
              ),
      testCase "R5: lifecycle epochs are exact per gov_action1 id" $
        rowUnexplained (row R5 (reconcileAll kOk (setRatified act (Just 229) pOk) []))
          @?= [Divergence act "ratified_epoch" "Just 228" "Just 229"],
      testCase "R5: the action type is compared through the Koios mapping" $
        rowUnexplained (row R5 (reconcileAll kOk (setActionType act InfoAction pOk) []))
          @?= [Divergence act "type" "Just ParameterChange" "Just InfoAction"],
      testCase "R6: the tally map is (role, verdict) -> count over final votes" $
        rowUnexplained (row R6 (reconcileAll kOk (setTally act DRep Yes 6 pOk) []))
          @?= [Divergence (act <> ":drep:yes") "count" "7" "6"],
      -- R7 is the gate on GET /votes returning every palmares.vote row rather than only the final
      -- ones: Koios's drep_votes keeps superseded votes, so dropping one here must be visible.
      testCase "R7: the vote-history set keeps superseded votes" $
        rowUnexplained (row R7 (reconcileAll kOk (dropVote pOk) []))
          @?= [Divergence (act <> ":yes:" <> voteTx) "membership" "present" "absent"],
      testCase "R8: the quorum is compared as a fraction, under its own key" $
        rowUnexplained (row R8 (reconcileAll kOk (setQuorum 3 3 pOk) []))
          @?= [Divergence "committee" "quorum" "2/3" "3/3"],
      testCase "R8: a member's hot key and term end are compared per cold id" $
        rowUnexplained (row R8 (reconcileAll kOk (setMemberExpiry coldId 400 pOk) []))
          @?= [Divergence coldId "expiration_epoch" "372" "400"],
      -- A multiset, not a set: the same beneficiary may legitimately appear twice in one action,
      -- and collapsing that would make a duplicated row invisible.
      testCase "R9: withdrawals are a (beneficiary, amount) multiset" $
        rowUnexplained (row R9 (reconcileAll kOk (dupWithdrawal pOk) []))
          @?= [Divergence (benef <> ":120000000000") "count" "1" "2"],
      testCase "R10 aborting skips every other row rather than faking a pass" $ do
        let rs = reconcileAll (setKoiosTipEpoch 322 kOk) pOk []
        rowStatus (row R10 rs) @?= RowDivergent
        assertBool
          "every other row is skipped"
          (all (\r -> rowId r == R10 || isSkipped (rowStatus r)) rs)
        length rs @?= 10,
      -- The lag bound is the same one /ready uses (D-7). A run against an index the service itself
      -- calls not-ready is comparing against something no client is being served.
      testCase "R10 aborts on lag alone, at the same bound /ready uses" $ do
        let rs = reconcileAll kOk (pOk {psLagSeconds = readyMaxLagSeconds + 1}) []
        (rowStatus (row R10 rs), readyMaxLagSeconds) @?= (RowDivergent, 300),
      testCase "a waived divergence becomes explained and the run exits 0" $ do
        let e =
              ExceptionEntry
                R2
                dA
                (Just "delegator_count")
                "Koios counts live where we count at the epoch"
                (fromGregorian 2026 10 20)
                "it@blazarlabs.io"
            rs = reconcileAll kOk (setDelegators dA 12 pOk) [e]
            rp = mkReport "preprod" t0 320 41 320 [e] rs
        rowStatus (row R2 rs) @?= RowOk
        (reportUnexplained rp, reportExplained rp, reportExitCode rp) @?= (0, 1, 0)
        reportStaleExceptions rp @?= []
    ]
  where
    row r rs = case filter ((== r) . rowId) rs of
      (x : _) -> x
      [] -> error ("UnitTests.Reconcile: no " <> show r <> " in the result")
    t0 = UTCTime (fromGregorian 2026 10 20) 0

-- ---------------------------------------------------------------------------------------------

-- | The ids the hand-built pair uses. Short, but the right SHAPE: the comparison keys are these
-- strings, and a test whose keys were @\"a\"@ and @\"b\"@ would not catch a renderer that dropped
-- the prefix.
dA, dB, act, coldId, hotHex, benef, voteTx :: Text
dA = "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
dB = "drep1ygpuetneftlmufa97hm5mf3xvqpdkyw656hyg6h20qaewtg3csnkc"
act = "gov_action1qnergwfcsse2y2mgxpp96z5pzjsk3tz745nk0lsj96u4d6ze8azqqdc2a6v"
coldId = "cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu"
hotHex = "5bfa7d850280c54110534065fa91a3635bbcc0eadc69c5c792c35e1e"
benef = "stake_test1uzrr46pd4wn2qpzvv5fpdeycndzsgjc899jn8e4rmten3ngcgm3f4"
voteTx = "05a64317c25d058d0be08db8e9a5728a257ab97af5b8d5d8c0a00df41bd3bcc5"

-- | The two reserved ledger options, which hold most of preprod's voting power (D-20).
abstainId, noConfId :: Text
abstainId = "drep_always_abstain"
noConfId = "drep_always_no_confidence"

-- | Koios's side of the consistent pair.
kOk :: KoiosSnapshot
kOk =
  KoiosSnapshot
    { ksTip = KoiosTip "deadbeef" 320 136841444 5315445 1792524644,
      ksDRepList =
        [ KoiosDRepListRow dA "81378d3e" False True,
          KoiosDRepListRow dB "03ccae79" False True
        ],
      ksDRepInfo = [kInfo dA 333 13, kInfo dB 324 1],
      ksPower =
        [ KoiosPowerRow dA 319 (KoiosLovelace 3923709956713),
          KoiosPowerRow dB 319 (KoiosLovelace 830756067101),
          KoiosPowerRow abstainId 319 (KoiosLovelace 431863790957959),
          KoiosPowerRow noConfId 319 (KoiosLovelace 325390800383)
        ],
      ksProposals = [kProposal],
      ksProposalVotes = M.singleton act (replicate 7 (kVote "DRep" "Yes")),
      ksDRepVotes = M.singleton dA [kDRepVote],
      ksCommittee = [kCommittee]
    }

kInfo :: Text -> Int -> Int -> KoiosDRepInfo
kInfo i expires delegators =
  KoiosDRepInfo
    { koiosDRepInfoId = i,
      koiosDRepInfoHex = "81378d3e",
      koiosDRepInfoHasScript = False,
      koiosDRepInfoStatus = "registered",
      koiosDRepInfoActive = True,
      koiosDRepInfoDeposit = Just (KoiosLovelace 500000000),
      koiosDRepInfoExpiresEpochNo = Just expires,
      koiosDRepInfoAmount = Just (KoiosLovelace 3923709956713),
      koiosDRepInfoMetaUrl = Nothing,
      koiosDRepInfoMetaHash = Nothing,
      koiosDRepInfoLiveDelegatorCount = delegators
    }

kProposal :: KoiosProposal
kProposal =
  KoiosProposal
    { koiosProposalId = act,
      koiosProposalTxHash = "04f23439",
      koiosProposalIndex = 0,
      koiosProposalType = "ParameterChange",
      koiosProposalDeposit = Just (KoiosLovelace 1000000000),
      koiosProposalReturnAddress = Just benef,
      koiosProposalProposedEpoch = Just 226,
      koiosProposalRatifiedEpoch = Just 228,
      koiosProposalEnactedEpoch = Just 229,
      koiosProposalDroppedEpoch = Nothing,
      koiosProposalExpiredEpoch = Nothing,
      koiosProposalExpiration = Just 233,
      koiosProposalMetaUrl = Nothing,
      koiosProposalMetaHash = Nothing,
      koiosProposalMetaIsValid = Nothing,
      koiosProposalWithdrawals = [KoiosWithdrawal benef (KoiosLovelace 120000000000)]
    }

kVote :: Text -> Text -> KoiosVoteRow
kVote role verdict = KoiosVoteRow role dA "81378d3e" False verdict 1740152025 Nothing Nothing

kDRepVote :: KoiosDRepVoteRow
kDRepVote = KoiosDRepVoteRow act "6056be57" 0 voteTx 1789327015 "Yes" Nothing Nothing

kCommittee :: KoiosCommittee
kCommittee =
  KoiosCommittee
    { koiosCommitteeProposalId = Just act,
      koiosCommitteeProposalTxHash = Just "bbfa303a",
      koiosCommitteeProposalIndex = Just 0,
      koiosCommitteeQuorumNumerator = 2,
      koiosCommitteeQuorumDenominator = 3,
      koiosCommitteeMembers =
        [ KoiosCommitteeMember "authorized" (Just "cc_hot1x") coldId (Just hotHex) "615b5413" (Just True) True (Just 372)
        ]
    }

-- | Our side of the consistent pair.
pOk :: PalmaresSnapshot
pOk =
  PalmaresSnapshot
    { psEpoch = 320,
      psLagSeconds = 41,
      psDReps =
        M.fromList
          [ (dA, PDRep False DRepActive (Just 333) 13),
            (dB, PDRep False DRepActive (Just 324) 1)
          ],
      psPower =
        M.fromList
          [ ((dA, 319), 3923709956713),
            ((dB, 319), 830756067101),
            ((abstainId, 319), 431863790957959),
            ((noConfId, 319), 325390800383)
          ],
      psActions = M.singleton act (PAction ParameterChange 226 (Just 233) (Just 228) (Just 229) Nothing Nothing),
      psTallies = M.singleton (act, DRep, Yes) 7,
      psVotes = S.singleton (act, Yes, voteTx),
      psCommittee = PCommittee 2 3 (M.singleton coldId (Just hotHex, 372)),
      psWithdrawals = M.singleton (benef, 120000000000) 1
    }

-- ---------------------------------------------------------------------------------------------

-- * One mutation each. Plain record updates, deliberately not library code.

dropDRep :: Text -> PalmaresSnapshot -> PalmaresSnapshot
dropDRep i p = p {psDReps = M.delete i (psDReps p)}

setActiveUntil :: Text -> Int -> PalmaresSnapshot -> PalmaresSnapshot
setActiveUntil i e p = p {psDReps = M.adjust (\d -> d {pdrepActiveUntilEpoch = Just e}) i (psDReps p)}

setDelegators :: Text -> Int -> PalmaresSnapshot -> PalmaresSnapshot
setDelegators i n p = p {psDReps = M.adjust (\d -> d {pdrepDelegatorCount = n}) i (psDReps p)}

setPower :: Text -> Int -> Integer -> PalmaresSnapshot -> PalmaresSnapshot
setPower i e v p = p {psPower = M.insert (i, e) v (psPower p)}

dropPower :: Text -> Int -> PalmaresSnapshot -> PalmaresSnapshot
dropPower i e p = p {psPower = M.delete (i, e) (psPower p)}

setRatified :: Text -> Maybe Int -> PalmaresSnapshot -> PalmaresSnapshot
setRatified a e p = p {psActions = M.adjust (\x -> x {pactionRatifiedEpoch = e}) a (psActions p)}

setActionType :: Text -> GovActionType -> PalmaresSnapshot -> PalmaresSnapshot
setActionType a t p = p {psActions = M.adjust (\x -> x {pactionType = t}) a (psActions p)}

setTally :: Text -> VoterRole -> Vote -> Int -> PalmaresSnapshot -> PalmaresSnapshot
setTally a role verdict n p = p {psTallies = M.insert (a, role, verdict) n (psTallies p)}

dropVote :: PalmaresSnapshot -> PalmaresSnapshot
dropVote p = p {psVotes = S.empty}

setQuorum :: Int -> Int -> PalmaresSnapshot -> PalmaresSnapshot
setQuorum n d p =
  p {psCommittee = (psCommittee p) {pcommitteeQuorumNumerator = n, pcommitteeQuorumDenominator = d}}

setMemberExpiry :: Text -> Int -> PalmaresSnapshot -> PalmaresSnapshot
setMemberExpiry cid e p =
  p {psCommittee = (psCommittee p) {pcommitteeMembers = M.adjust (\(h, _) -> (h, e)) cid (pcommitteeMembers (psCommittee p))}}

dupWithdrawal :: PalmaresSnapshot -> PalmaresSnapshot
dupWithdrawal p = p {psWithdrawals = M.map (+ 1) (psWithdrawals p)}

setKoiosTipEpoch :: Int -> KoiosSnapshot -> KoiosSnapshot
setKoiosTipEpoch e k = k {ksTip = (ksTip k) {koiosTipEpochNo = e}}

setKoiosActive :: Text -> Bool -> KoiosSnapshot -> KoiosSnapshot
setKoiosActive i a k =
  k {ksDRepInfo = [if koiosDRepInfoId x == i then x {koiosDRepInfoActive = a} else x | x <- ksDRepInfo k]}

-- ---------------------------------------------------------------------------------------------

-- | The shipped sample, gated against the spec's own floor.
--
-- CI runs this, so the floor cannot silently regress: a sample that shrank below 20 DReps or 10
-- actions would still reconcile cleanly and would still be a weaker check than the spec asked for,
-- and nothing else in the suite would notice.
sampleTests :: TestTree
sampleTests =
  testGroup
    "Reconcile sample"
    [ testCase "the shipped sample meets the spec floor and is pinned, not drawn" $ do
        s <- loadSample "config/reconcile-sample.preprod.json" >>= either assertFailure pure
        (sampleNetwork s, sampleRecordedAtEpoch s) @?= ("preprod", 320)
        assertBool ">= 20 DReps (spec floor)" (length (sampleVoteHistoryDreps s) >= 20)
        assertBool ">= 10 gov actions (spec floor)" (length (sampleTallyActions s) >= 10),
      -- Both lists are keys that both sides join on, so a malformed id is not a weaker check, it
      -- is a row that compares nothing and reports ok.
      testCase "every id is the CIP-129 form both sides key on" $ do
        s <- loadSample "config/reconcile-sample.preprod.json" >>= either assertFailure pure
        ( filter (not . T.isPrefixOf "drep1") (sampleVoteHistoryDreps s),
          filter (not . T.isPrefixOf "gov_action1") (sampleTallyActions s)
          )
          @?= ([], []),
      -- A duplicate would inflate `compared` without comparing anything more, which is the one way
      -- a sample can look larger than it is.
      testCase "no id appears twice, and the file is sorted so a redraw diffs cleanly" $ do
        s <- loadSample "config/reconcile-sample.preprod.json" >>= either assertFailure pure
        ( nub (sampleVoteHistoryDreps s) == sampleVoteHistoryDreps s,
          nub (sampleTallyActions s) == sampleTallyActions s,
          sort (sampleVoteHistoryDreps s) == sampleVoteHistoryDreps s,
          sort (sampleTallyActions s) == sampleTallyActions s
          )
          @?= (True, True, True, True),
      -- The worked example's 16 votes are not guaranteed to reach the top 30 by vote count, so it
      -- is in the sample explicitly. This is what says so.
      testCase "the worked-example DRep is in the sample" $ do
        s <- loadSample "config/reconcile-sample.preprod.json" >>= either assertFailure pure
        assertBool
          "the T-METRIC worked example is present"
          ("drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg" `elem` sampleVoteHistoryDreps s),
      testCase "a missing sample file is a Left, not an empty sample" $ do
        r <- loadSample "config/does-not-exist.json"
        case r of
          Left _ -> pure ()
          Right _ -> assertFailure "a missing sample must not read as zero ids"
    ]
