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
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Types (DRepStatus (..), GovActionType (..), Vote (..), VoterRole (..))
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
      mappingTests
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
