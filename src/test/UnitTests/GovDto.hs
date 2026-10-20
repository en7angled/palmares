{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Golden JSON for the governance wire vocabulary.
--
-- These are byte-for-byte assertions on 'encode', not round-trip properties, because the wire
-- format is the contract: a frontend, a CSV export and a Koios comparison all read these exact
-- strings. A round-trip test would pass happily while renaming every field.
--
-- The identifier vectors are read off our own synced preprod db-sync, not copied from a design
-- note. @drep_hash.view@ gave the CIP-105 string and @gov_action_proposal@ joined to @tx@ gave the
-- governance action; the CIP-129 forms are this codebase's own encoders, cross-checked against the
-- BIP-173 reference implementation in @UnitTests.GovIds@.
module UnitTests.GovDto (govDtoTests) where

import Data.Aeson (decode, encode, toJSON)
import Data.Text (Text)
import Data.Time (UTCTime)
import Palmares.DomainTypes.Core.Types
import Servant (parseUrlPiece)
import Test.Tasty
import Test.Tasty.HUnit

-- | Bitcows, the fixture DRep: CIP-129 id, CIP-105 view, raw 28-byte credential hash.
bitcowsCip129, bitcowsCip105, bitcowsHex :: Text
bitcowsCip129 = "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
bitcowsCip105 = "drep1symc604gnd50plqfj393lyljl6u9zvv0r9he3wjq98v2sz3vtkp"
bitcowsHex = "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"

-- | preprod's first governance action: @gov_action_proposal.id = 1@, a ParameterChange. Pinned
-- because it is the earliest, so no later proposal can change what this vector means.
actionTxHex, actionCip129, actionCanonical :: Text
actionTxHex = "0ecc74fe26532cec1ab9a299f082afc436afc888ca2dc0fc6acda431c52dc60d"
actionCip129 = "gov_action1pmx8fl3x2vkwcx4e52vlpq40csm2ljygegkuplr2ekjrr3fdccxsq0jegy9"
actionCanonical = actionTxHex <> "#0"

govDtoTests :: TestTree
govDtoTests =
  testGroup
    "governance DTO wire format"
    [ testCase "tx-borne ChainPoint" $
        encode (ChainPoint (Just 84233900) 215 (read "2026-10-19 08:14:02 UTC" :: UTCTime) (Just "a1b2"))
          @?= "{\"slot\":84233900,\"epoch\":215,\"time\":\"2026-10-19T08:14:02Z\",\"tx_hash\":\"a1b2\"}",
      -- The epoch-boundary case is the one that must not collapse to an absent key: a client
      -- distinguishing "no transaction" from "field not implemented" needs the explicit null.
      testCase "epoch-boundary ChainPoint has null slot and null tx_hash" $
        encode (ChainPoint Nothing 215 (read "2026-10-19 00:00:00 UTC" :: UTCTime) Nothing)
          @?= "{\"slot\":null,\"epoch\":215,\"time\":\"2026-10-19T00:00:00Z\",\"tx_hash\":null}",
      -- VoterRole is the one enum where CamelToSnake is WRONG: it gives d_rep and s_p_o.
      testCase "VoterRole wire values are hand-written" $
        map toJSON [DRep, SPO, ConstitutionalCommittee]
          @?= ["drep", "spo", "constitutional_committee"],
      testCase "VoterRole round-trips" $
        mapM (decode . encode) [DRep, SPO, ConstitutionalCommittee]
          @?= Just [DRep, SPO, ConstitutionalCommittee],
      testCase "GovActionType uses db-sync's NewCommittee, snake_cased" $
        map
          toJSON
          [ ParameterChange,
            HardForkInitiation,
            TreasuryWithdrawals,
            NoConfidence,
            NewCommittee,
            NewConstitution,
            InfoAction
          ]
          @?= [ "parameter_change",
                "hard_fork_initiation",
                "treasury_withdrawals",
                "no_confidence",
                "new_committee",
                "new_constitution",
                "info_action"
              ],
      testCase "AnchorStatus has seven values" $
        map
          toJSON
          [ AnchorValid,
            AnchorInvalidSchema,
            AnchorHashMismatch,
            AnchorOversized,
            AnchorUnreachable,
            AnchorInline,
            AnchorNotFetched
          ]
          @?= [ "valid",
                "invalid_schema",
                "hash_mismatch",
                "oversized",
                "unreachable",
                "inline",
                "not_fetched"
              ],
      testCase "ActivityEventType is snake_case, not the Belt System's PascalCase" $
        map toJSON [EvtDrepRegistered, EvtVoteCast, EvtGovActionRatified, EvtTreasuryWithdrawalEnacted]
          @?= ["drep_registered", "vote_cast", "gov_action_ratified", "treasury_withdrawal_enacted"],
      -- Thirteen, matching palmares.activity.event_type one for one. Two of them are unreachable
      -- on preprod (no committee has resigned, no treasury withdrawal has been enacted), which is
      -- why the completeness assertion is here and not in a check against live data.
      testCase "ActivityEventType has all thirteen of the feed's kinds" $
        map toJSON ([minBound .. maxBound] :: [ActivityEventType])
          @?= [ "drep_registered",
                "drep_updated",
                "drep_retired",
                "delegation_changed",
                "vote_cast",
                "gov_action_proposed",
                "gov_action_ratified",
                "gov_action_enacted",
                "gov_action_expired",
                "gov_action_dropped",
                "committee_authorized",
                "committee_resigned",
                "treasury_withdrawal_enacted"
              ],
      testCase "DRepStatus / DRepUpdateKind / GovActionState / Vote / TallyBasis" $
        ( map toJSON [DRepActive, DRepInactive, DRepRetired, DRepReserved],
          map toJSON [UpdateKindRegistered, UpdateKindUpdated, UpdateKindRetired],
          map toJSON [Proposed, Ratified, Enacted, Expired, Dropped],
          map toJSON [Yes, No, Abstain],
          toJSON CastVotesOnly
        )
          @?= ( ["active", "inactive", "retired", "reserved"],
                ["registered", "updated", "retired"],
                ["proposed", "ratified", "enacted", "expired", "dropped"],
                ["yes", "no", "abstain"],
                "cast_votes_only"
              ),
      -- Both of these have a single nullary constructor, which aeson encodes as an empty ARRAY
      -- unless TagSingleConstructors is set. Asserted separately so the next single-constructor
      -- enum someone adds fails here rather than on the wire.
      testCase "the single-constructor enums are strings, not empty arrays" $
        (toJSON CastVotesOnly, toJSON SourceGovernance)
          @?= ("cast_votes_only", "governance"),
      testCase "SearchKind names the six groups the palette renders" $
        map toJSON ([minBound .. maxBound] :: [SearchKind])
          @?= ["drep", "gov_action", "spo", "committee_member", "profile", "attestation"],
      -- Two values, not Koios's four: the view derives status from committee_de_registration
      -- alone, and expiry is published beside it as expiration_epoch.
      testCase "CommitteeMemberStatus mirrors palmares.committee_member" $
        map toJSON ([minBound .. maxBound] :: [CommitteeMemberStatus])
          @?= ["active", "resigned"],
      testCase "capture accepts CIP-129, CIP-105, raw hex and the two reserved views" $
        traverse
          (parseUrlPiece @DRepId)
          [bitcowsCip129, bitcowsCip105, bitcowsHex, "drep_always_abstain", "drep_always_no_confidence"]
          @?= Right
            ( map
                DRepId
                [ bitcowsCip129,
                  bitcowsCip129,
                  bitcowsCip129,
                  "drep_always_abstain",
                  "drep_always_no_confidence"
                ]
            ),
      testCase "capture normalises to CIP-129 and rejects junk" $
        parseUrlPiece @DRepId "pool1abc" @?= Left "invalid_drep_id",
      -- The script form must survive the round trip, because the header byte is the only thing
      -- that distinguishes it and a key-form answer would name a different credential.
      testCase "a script DRep's CIP-129 id keeps its header byte" $
        parseUrlPiece @DRepId "drep1ywqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmuzqx0"
          @?= Right (DRepId "drep1ywqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmuzqx0"),
      testCase "GovActionId capture accepts both forms, canonical is tx#index" $
        traverse (parseUrlPiece @GovActionId) [actionCanonical, actionCip129]
          @?= Right [GovActionId actionCanonical, GovActionId actionCanonical],
      testCase "GovActionId rejects a short hash, a bad index and a foreign HRP" $
        map
          (parseUrlPiece @GovActionId)
          ["0ecc74fe#0", actionTxHex <> "#x", bitcowsCip129, actionTxHex]
          @?= replicate 4 (Left "invalid_gov_action_id")
    ]
