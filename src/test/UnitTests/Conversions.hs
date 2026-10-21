{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the conversions that cross a layer boundary.
--
-- Two families. First, on-chain text (F-09): the encode/decode round-trip must preserve non-ASCII,
-- and decoding invalid UTF-8 must not throw. Second, the attestation's shape across the three
-- boundaries it crosses — on-chain enum ↔ domain enum ↔ wire JSON — because the domain
-- 'Attestation' has a HAND-WRITTEN 'FromJSON' with one positional application per field against a
-- DERIVED 'ToJSON', and nothing but a round-trip notices when the two stop agreeing.
module UnitTests.Conversions (conversionsTests) where

import Control.Exception (evaluate, try, SomeException)
import Control.Lens ((^.))
import Data.Aeson (Value (Object), eitherDecode, encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import qualified Data.ByteString
import Data.Proxy (Proxy (..))
import Data.Swagger (enum_, toSchema)
import qualified Data.Text as T
import GeniusYield.Types (GYAssetClass, timeFromPlutus)
import Palmares.ChainSync.KupoAtlas (toGYAssetClass)
import Palmares.DomainTypes.Core.Types (Attestation (..), AttestationType (..), ProfileType)
import PlutusLedgerApi.V3 (POSIXTime (POSIXTime))
import PlutusTx.Builtins (toBuiltin)
import Test.Tasty
import Test.Tasty.HUnit
import Palmares.TxBuilding.Conversions
  ( attestationTypeToOnchainAttestationKind,
    fromBuiltinByteStringUtf8,
    onchainAttestationKindToAttestationType,
    textToBuiltinByteString,
  )

roundTrip :: T.Text -> T.Text
roundTrip = fromBuiltinByteStringUtf8 . textToBuiltinByteString

ac :: T.Text -> GYAssetClass
ac t = either (error "bad asset class fixture") id (toGYAssetClass t)

-- | Every field distinct, and the three 'GYAssetClass' fields distinct from each other — that is the
-- point of the fixture rather than an accident of it. The id, the subject and the issuer are the same
-- type, so a transposition between them type-checks everywhere; only differing VALUES turn it into a
-- failed assertion.
sampleAttestation :: Attestation
sampleAttestation =
  Attestation
    { attestationId = ac "00000000000000000000000000000000000000000000000000000000.6161",
      attestationSubjectProfileId = ac "00000000000000000000000000000000000000000000000000000000.6262",
      attestationIssuerProfileId = ac "00000000000000000000000000000000000000000000000000000000.6363",
      attestationKind = Affiliation,
      attestationAttestationDate = timeFromPlutus (POSIXTime 1700000000000),
      -- A period that STARTS BEFORE the issuance date, which is the case the field exists for and
      -- the one the strict reading would have made unrepresentable.
      attestationClaimedPeriod =
        Just (timeFromPlutus (POSIXTime 1600000000000), timeFromPlutus (POSIXTime 1650000000000)),
      attestationAccepted = True,
      attestationName = "Affiliation with Intersect",
      attestationDescription = "member since 2024",
      attestationImageURI = "ipfs://img",
      attestationOtherMetadata = [("source", "self-reported")],
      attestationTxHash = Just "ab12",
      attestationSlot = Just 7,
      attestationOutputIndex = Just 1
    }

conversionsTests :: TestTree
conversionsTests =
  testGroup
    "Conversions (F-09 UTF-8)"
    [ testCase "ASCII round-trips" $ roundTrip "Hello World" @?= "Hello World",
      testCase "accented text round-trips" $ roundTrip "José Gração" @?= "José Gração",
      testCase "emoji round-trips" $ roundTrip "vendor \128081 test" @?= "vendor \128081 test",
      testCase "empty round-trips" $ roundTrip "" @?= "",
      testCase "invalid UTF-8 bytes do not throw (lenient)" $ do
        -- 0xFF 0xFE are not valid UTF-8; decoding must yield a Text without raising.
        let bad = toBuiltin (Data.ByteString.pack [0x41, 0xFF, 0xFE, 0x42])
        r <- try (evaluate (T.length (fromBuiltinByteStringUtf8 bad)))
        case r of
          Right _ -> pure ()
          Left (e :: SomeException) -> assertFailure ("decode threw: " <> show e),
      -- ---- the attestation kind across the layer boundary ------------------------------------
      --
      -- Both mappings are written arm by arm rather than through `fromEnum`, so the thing that can
      -- go wrong is a pair of arms crossed — which type-checks, because every arm has the same type.
      -- Driving the test off [minBound .. maxBound] means a sixth kind is covered the moment it is
      -- added, instead of being covered by whichever list someone remembered to extend.
      testCase "every attestation kind round-trips through the on-chain enum" $
        map (onchainAttestationKindToAttestationType . attestationTypeToOnchainAttestationKind) allKinds
          @?= allKinds,
      -- The wire spelling is what a client branches on, so it is pinned by value. These five strings
      -- are the published contract; the derived CamelToSnake is just how they are produced.
      testCase "the attestation kinds' wire tags are snake_case" $
        map toJSON allKinds
          @?= ["milestone_delivered", "audit_passed", "affiliation", "role_held", "endorsement"],
      -- ---- the attestation's wire shape ------------------------------------------------------
      --
      -- `ToJSON` is DERIVED from `StripPrefix "attestation"` and `FromJSON` is HAND-WRITTEN with a
      -- literal key per field, in record order. That is two independent spellings of the same
      -- contract, and T-ATTEST-1 already shipped a case where a stale prefix renamed every key while
      -- compiling perfectly. A round-trip is what makes the two disagree loudly: a key the encoder
      -- stopped emitting fails the decode, and a field bound into the wrong slot comes back with
      -- another field's value.
      testCase "an Attestation survives encode then decode, claimed period included" $
        case eitherDecode (encode sampleAttestation) of
          Left e -> assertFailure ("decode failed: " <> e)
          Right (decoded :: Attestation) -> toJSON decoded @?= toJSON sampleAttestation,
      testCase "an Attestation with no claimed period round-trips as Nothing" $
        case eitherDecode (encode sampleAttestation {attestationClaimedPeriod = Nothing}) of
          Left e -> assertFailure ("decode failed: " <> e)
          Right (decoded :: Attestation) -> attestationClaimedPeriod decoded @?= Nothing,
      -- And the published NAMES, which a round-trip alone cannot pin: if both sides agreed on a
      -- wrong key the round-trip would still pass. `claimed_period` must not be `period` and must
      -- not collapse into `attestation_date` — the whole decision was that the two are different
      -- kinds of fact and a reader must be able to tell them apart.
      testCase "the published keys are kind, attestation_date and claimed_period" $
        case toJSON sampleAttestation of
          Object o ->
            ( KeyMap.member "kind" o,
              KeyMap.member "attestation_date" o,
              KeyMap.member "claimed_period" o
            )
              @?= (True, True, True)
          v -> assertFailure ("an Attestation must encode as an object, got: " <> show v),
      -- ---- the published enum values must be the accepted enum values -------------------------
      --
      -- A MEASURED defect, not a hypothetical one. `AttestationType` first shipped with a DERIVED
      -- `ToSchema`, which publishes the CONSTRUCTOR names — the generated
      -- interaction-swagger-api.json read ["MilestoneDelivered", …] while `FromJSON` accepts
      -- ["milestone_delivered", …]. The document described five values the API rejects, it compiled,
      -- and nothing failed. Every other enum in DomainTypes.Core.Types already reads its schema out
      -- of `ToJSON` with `jsonEnumSchema`; the derived instance is the trap, and `ProfileType` was
      -- sitting in it too — latently, since no documented route mentions a profile type yet.
      --
      -- This is the guard for the whole class: the schema's enum must BE the ToJSON tags. It fails
      -- on a derived instance and passes on a jsonEnumSchema one.
      testCase "AttestationType's published schema lists the values the API accepts" $
        (toSchema (Proxy :: Proxy AttestationType) ^. enum_)
          @?= Just (map toJSON allKinds),
      testCase "ProfileType's published schema lists the values the API accepts" $
        (toSchema (Proxy :: Proxy ProfileType) ^. enum_)
          @?= Just (map toJSON ([minBound .. maxBound] :: [ProfileType]))
    ]
  where
    allKinds = [minBound .. maxBound] :: [AttestationType]
