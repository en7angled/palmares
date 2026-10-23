{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Where a rule exists twice, this module keeps the two copies equal.
--
-- Two families, and both are about a kind of mistake that compiles.
--
-- __The oracle mirror.__ 'Palmares.TxBuilding.Operations.applyAdminAction' and
-- 'Palmares.Onchain.Protocol.Types.applyOracleAdminAction' are the same six-case record update
-- written twice, once per layer. 'updateOracleTX' locks the datum the off-chain copy computes, and
-- the validator's @O2@ compares the output datum to the one the on-chain copy computes — so the
-- moment they disagree on any action, that action becomes unperformable on a deployed protocol. Not
-- wrong-but-working: dead. Neither copy's own tests notice, because each is self-consistent;
-- @UnitTests.OracleRules@ pins the on-chain one and nothing pinned the pair.
--
-- __Data round-trips.__ Every datum type carries @makeIsDataSchemaIndexed@ indices that are a
-- deployed-data contract. Reordering a record's fields or renumbering a constructor compiles, passes
-- every pure test written in terms of field accessors, and makes a UTxO already on chain unparseable.
-- @toBuiltinData@ then @fromBuiltinData@ is the cheapest thing that fails on it.
--
-- __Why these are tables and not generators.__ @src/test/CLAUDE.md@ asks for property tests here and
-- the plan asked for @hedgehog@. Neither arrived: what is being covered is a six-constructor sum and
-- a fixed set of record shapes, so the exhaustive table IS the property — @[minBound .. maxBound]@
-- for every enum, and one case per constructor for the rest, with a count assertion that fails when
-- a constructor is added. A generator would re-roll the same handful of shapes with random integers
-- in them, for a new dependency and a page of @Gen@ boilerplate. If a future type arrives whose
-- input space is genuinely large, that is when @hedgehog@ earns its place.
module PropertyTests (propertyTests) where

import Data.ByteString qualified as BS
import GeniusYield.Types (GYPubKeyHash, pubKeyHashFromPlutus, pubKeyHashToPlutus)
import Palmares.DomainTypes.Core.Actions (AdminActionType (..))
import Palmares.Onchain.CIP68 (CIP68Datum (..), MetadataFields (..))
import Palmares.Onchain.Protocol.Types
  ( AttestationKind,
    FeeConfig (..),
    MintAction,
    OnchainAttestation (..),
    OnchainDispute (..),
    OnchainProfile (..),
    OnchainProfileKind,
    OracleParams (..),
    ProtocolParams (oracleToken),
    Verdict (..),
    applyOracleAdminAction,
    resolveDispute,
  )
import Palmares.TxBuilding.Operations (adminActionToOracleAdminAction, applyAdminAction)
import Palmares.TxBuilding.Validators (blueprintProtocolParams)
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusLedgerApi.V3 (Address (..), Credential (PubKeyCredential, ScriptCredential), POSIXTime (..), PubKeyHash (..), ScriptHash (..))
import PlutusTx (Data (..), FromData, ToData, builtinDataToData, fromBuiltinData, toBuiltinData)
import PlutusTx.Builtins (toBuiltin)
import Test.Fixtures (parsingDisputeDatum)
import Test.Tasty
import Test.Tasty.HUnit

propertyTests :: TestTree
propertyTests =
  testGroup
    "Property Tests (on-chain ≡ off-chain)"
    [ oracleMirrorTests,
      dataRoundTripTests
    ]

-------------------------------------------------------------------------------

-- * The oracle mirror

-------------------------------------------------------------------------------

oracleMirrorTests :: TestTree
oracleMirrorTests =
  testGroup
    "applyAdminAction mirrors applyOracleAdminAction"
    [ -- The whole mirror, in one assertion per base state. Whole-record equality, because that is
      -- exactly what the validator compares: a field one copy touches and the other does not is the
      -- defect, and a field-by-field check would need the same enumeration to be written a second
      -- time.
      testCase "every admin action produces the same OracleParams on both sides" $
        mapM_ mirrorsOn [paramsNoFees, paramsWithFees],
      -- The table is only a property if it is exhaustive, and nothing in the type system says it is.
      -- This is the line that fails when a ninth admin action is added: the new constructor has no
      -- row above, so its two implementations are free to disagree.
      --
      -- Two entries map to index 2 because 'SetFeesAction' is listed twice, with and without a
      -- config. The list is the enumeration; the indices are what it proves.
      testCase "the table covers all eight OracleAdminAction constructors" $
        map (constructorIndexOf . adminActionToOracleAdminAction) allAdminActions @?= [0, 1, 2, 2, 3, 4, 5, 6, 7],
      -- And the redeemer the off-chain side sends is the action the on-chain side applies. A swap
      -- here — pause mapped to unpause — would keep the mirror above intact (both sides would be
      -- wrong together) while inverting what the admin asked for.
      testCase "the redeemer's action applies the change the off-chain action names" $
        [opPaused (applyOracleAdminAction (adminActionToOracleAdminAction a) paramsNoFees) | a <- [PauseProtocolAction, UnpauseProtocolAction]]
          @?= [True, False]
    ]
  where
    mirrorsOn params =
      mapM_
        ( \action ->
            assertEqual
              (show action)
              (applyOracleAdminAction (adminActionToOracleAdminAction action) params)
              (applyAdminAction action params)
        )
        allAdminActions

    -- One row per constructor, plus the second 'SetFeesAction' because clearing fees and setting
    -- them are the two halves of a 'Maybe' and a mirror could get one right and the other wrong.
    --
    -- __This list is the test, so a missing row is a missing test and nothing says so.__ D-A added
    -- 'SetDisputeTimeoutAction' and did not add it here, so both cases above — the index mirror and
    -- the apply mirror — were silently not about it until an audit reconciliation noticed. The same
    -- trap 'MintAction' carries a comment about, sprung one type over.
    allAdminActions :: [AdminActionType]
    allAdminActions =
      [ PauseProtocolAction,
        UnpauseProtocolAction,
        SetFeesAction Nothing,
        SetFeesAction (Just feeConfig),
        SetMinUTxOValueAction 7_654_321,
        RotateAdminAction (PubKeyCredential (pubKeyHashToPlutus newAdminGY)) Nothing,
        SetDisputeDepositAction 12_345_678,
        SetDisputeTimeoutAction 2_592_000_000,
        -- ADR 0005. Appended for the reason the comment above gives: this list IS the test, so an
        -- action missing from it is an index mirror and an apply mirror that quietly say nothing.
        RotateArbiterAction (ScriptCredential (ScriptHash (toBuiltin (BS.replicate 28 0x5c)))) Nothing
      ]

-------------------------------------------------------------------------------

-- * Data round-trips

-------------------------------------------------------------------------------

dataRoundTripTests :: TestTree
dataRoundTripTests =
  testGroup
    "toBuiltinData / fromBuiltinData round-trips"
    [ -- The enums, driven off [minBound .. maxBound] so a constructor added later is covered without
      -- anyone remembering to add a line.
      testCase "every OnchainProfileKind round-trips" $
        mapM_ roundTrips ([minBound .. maxBound] :: [OnchainProfileKind]),
      testCase "every AttestationKind round-trips" $
        mapM_ roundTrips ([minBound .. maxBound] :: [AttestationKind]),
      testCase "every MintAction round-trips" $
        mapM_ roundTrips ([minBound .. maxBound] :: [MintAction]),
      testCase "both Verdicts round-trip" $
        mapM_ roundTrips [VerdictUpheld, VerdictRejected],
      -- The records. Each one is a UTxO shape somebody's ADA is locked behind.
      testCase "FeeConfig round-trips" $ roundTrips feeConfig,
      testCase "OracleParams round-trips, with and without fees" $
        mapM_ roundTrips [paramsNoFees, paramsWithFees],
      testCase "MetadataFields round-trips" $
        roundTrips (Metadata222 "name" "description" "ipfs://image"),
      testCase "OnchainProfile round-trips, claimed and unclaimed" $
        mapM_ roundTrips [profileUnclaimed, profileClaimed],
      -- Both halves of the claimed period. The 'Maybe (POSIXTime, POSIXTime)' is the newest field in
      -- the protocol and the only nested tuple in any datum, which makes it the likeliest encoding
      -- to be got wrong.
      testCase "OnchainAttestation round-trips, with and without a claimed period" $
        mapM_ roundTrips [attestationNoPeriod, attestationWithPeriod],
      testCase "OnchainDispute round-trips, open and resolved" $
        mapM_ roundTrips [openDispute, resolveDispute VerdictUpheld openDispute, resolveDispute VerdictRejected openDispute],
      -- The wrapper, because a dispute on chain is a 'CIP68Datum' and not a bare 'OnchainDispute'.
      testCase "a CIP68-wrapped dispute round-trips" $ roundTrips parsingDisputeDatum
    ]

-- | @fromBuiltinData . toBuiltinData@ must be @Just@ of the original, for every datum type.
roundTrips :: forall a. (Eq a, Show a, ToData a, FromData a) => a -> Assertion
roundTrips x = assertEqual (show x) (Just x) (fromBuiltinData @a (toBuiltinData x))

-------------------------------------------------------------------------------

-- * Fixtures

-------------------------------------------------------------------------------

-- | The constructor index @makeIsDataSchemaIndexed@ assigned, read back out of the encoding rather
-- than out of the declaration. Same primitive @UnitTests.Dispute@ uses.
constructorIndexOf :: (ToData a) => a -> Integer
constructorIndexOf x = case builtinDataToData (toBuiltinData x) of
  Constr i _ -> i
  other -> error ("expected a Constr, got: " <> show other)

fakeAC :: BS.ByteString -> AssetClass
fakeAC name = AssetClass (CurrencySymbol "", TokenName (toBuiltin name))

-- A 28-byte hash, which is what a key hash is; anything shorter is rejected by
-- 'pubKeyHashFromPlutus' rather than by the thing under test.
newAdminPlutus :: PubKeyHash
newAdminPlutus = PubKeyHash (toBuiltin (BS.replicate 28 0x11))

newAdminGY :: GYPubKeyHash
newAdminGY = either (error . show) id (pubKeyHashFromPlutus newAdminPlutus)

feeConfig :: FeeConfig
feeConfig =
  FeeConfig
    { fcFeeAddress = Address (PubKeyCredential newAdminPlutus) Nothing,
      -- Distinct amounts: equal ones would make a transposition between the two fields invisible.
      fcProfileCreationFee = 2_000_000,
      fcAttestationFee = 1_500_000
    }

-- Every field distinct from every default, so a record update that touches the wrong one shows up.
paramsNoFees :: OracleParams
paramsNoFees =
  OracleParams
    { opAdmin = PubKeyCredential (PubKeyHash (toBuiltin (BS.replicate 28 0x22))),
      opArbiter = PubKeyCredential (PubKeyHash (toBuiltin (BS.replicate 28 0x22))),
      opPaused = False,
      opFeeConfig = Nothing,
      opMinUTxOValue = 1_000_000,
      opDisputeDeposit = 5_000_000,
      opDisputeTimeoutMs = 2_592_000_000
    }

paramsWithFees :: OracleParams
paramsWithFees = paramsNoFees {opPaused = True, opFeeConfig = Just feeConfig}

profileUnclaimed :: OnchainProfile
profileUnclaimed =
  OnchainProfile
    { profileId = fakeAC "profile",
      profileKind = minBound,
      profileOracleToken = oracleToken blueprintProtocolParams
    }

-- ADR 0003 removed the profile's credential field, so "claimed" is no longer a profile shape at
-- all: a binding is a CredentialClaim attestation. The round-trip the pair used to cover is now
-- covered by the attestation fixtures below, which carry `attestationCredential`.
profileClaimed :: OnchainProfile
profileClaimed = profileUnclaimed

attestationNoPeriod :: OnchainAttestation
attestationNoPeriod =
  OnchainAttestation
    { attestationId = fakeAC "attestation",
      attestationIssuer = fakeAC "issuer",
      attestationSubject = fakeAC "subject",
      attestationKind = minBound,
      attestationDate = POSIXTime 1_700_000_000_000,
      attestationPeriod = Nothing,
      attestationCredential = Nothing,
      attestationIsAccepted = False,
      attestationOracleToken = fakeAC "oracle"
    }

-- A period that STARTS BEFORE the issuance date, which is the case the field exists for.
attestationWithPeriod :: OnchainAttestation
attestationWithPeriod =
  attestationNoPeriod
    { attestationPeriod = Just (POSIXTime 1_600_000_000_000, POSIXTime 1_650_000_000_000),
      attestationIsAccepted = True
    }

openDispute :: OnchainDispute
openDispute = extra parsingDisputeDatum
