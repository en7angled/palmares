{-# LANGUAGE OverloadedStrings #-}

-- | What 'Palmares.Ingestion.projectChainEvent' will and will not turn into protocol state, and
-- what a rollback replay puts back.
--
-- __Inherited fix #3, the half that was missing.__ @UnitTests.ChainSyncReplay@ already pins
-- 'Palmares.TxBuilding.Utils.authenticateStateUTxO' as a predicate, but nothing called it:
-- 'Palmares.Ingestion.projectChainEvent' dispatched on @(address, the datum parses)@ and nothing
-- else. Since no validator ever runs on an output nobody spends, anyone could pay 2 ADA and a
-- hand-crafted inline datum to the Profiles address and the read API would serve it as a profile.
-- The first case below is that forgery, and it fails on the old behaviour: before the fix it
-- projected a profile.
--
-- __Review Focus item 5.__ @UnitTests.StorageRoundtrip@ calls 'Palmares.Storage.rollbackTo' but
-- asserts only raw-match counts, and its fixture address is the literal @\"addr\"@, which
-- 'addressFromTextMaybe' rejects — so every match took the conversion-error branch and the
-- projection replay was exercised only in its failure path. The fixtures here are real addresses
-- and real inline datums, and the snapshot assertions are non-vacuous by construction: each one
-- first asserts there is something to lose.
module UnitTests.Projections (tests) where

import Cardano.Api qualified as Api
import Control.Monad.Except (runExcept)
import Data.ByteString.Base16 qualified as B16
import Data.List (sort)
import Data.Map qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.Persist (Entity (..), Filter, SelectOpt (Asc), selectList, (==.))
import Database.Persist.Sql (ConnectionPool)
import GeniusYield.Types
import Palmares.ChainSync.KupoAtlas (AtlasMatch (..), toGYAssetClass)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..), KupoValue (..))
import Palmares.DomainTypes.Core.Types (Profile (..))
import Palmares.Ingestion
import Palmares.Onchain.CIP68 (MetadataFields (..), mkCIP68Datum)
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Storage
import Palmares.TxBuilding.Conversions (claimCredentialToText)
import Palmares.TxBuilding.Validators
  ( attestationsValidatorHashGY,
    attestationsValidatorHashPlutus,
    disputesValidatorHashGY,
    disputesValidatorHashPlutus,
    oracleValidatorHashGY,
    profilesValidatorHashGY,
    profilesValidatorHashPlutus,
  )
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusLedgerApi.V3 (Address (..), BuiltinByteString, Credential (PubKeyCredential), POSIXTime (..), PubKeyHash (..))
import Test.Pg (runPg, withScratchDb)
-- `after` is tasty's dependency-ordering combinator and nothing here uses it, while four tests
-- below bind a snapshot called `after` beside a `before`. Hidden rather than renamed, which is the
-- same choice `query-api/RestAPI.hs` makes for `Control.Lens`.
import Test.Tasty hiding (after)
import Test.Tasty.HUnit

------------------------------------------------------------------------------------------------

-- * Fixtures

------------------------------------------------------------------------------------------------

testNetworkId :: GYNetworkId
testNetworkId = GYTestnetPreview

-- 56 hex chars = the 28-byte script hash GYMintingPolicyId's IsString instance requires.
ourPolicy :: GYMintingPolicyId
ourPolicy = "c0ffee00000000000000000000000000000000000000000000000001"

ac :: Text -> GYAssetClass
ac t = either (error . ("bad asset-class fixture: " <>)) id (toGYAssetClass t)

-- Five ids under our policy, plus one under somebody else's.
acProfileA, acProfileB, acProfileC, acAttestation, acDispute, acForeign :: GYAssetClass
acProfileA = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0a1"
acProfileB = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0b2"
acProfileC = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0c3"
acAttestation = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0d4"
acDispute = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0e5"
acForeign = ac "deadbeef000000000000000000000000000000000000000000000002.000643b0f6"

-- | The credential two of the profiles below both claim — Review Focus item 2.
testCredential :: Credential
testCredential = PubKeyCredential (PubKeyHash "0123456789abcdef0123456789ab")

profilesAddress, attestationsAddress, disputesAddress, unindexedAddress :: GYAddress
profilesAddress = addressFromScriptHash testNetworkId profilesValidatorHashGY
attestationsAddress = addressFromScriptHash testNetworkId attestationsValidatorHashGY
disputesAddress = addressFromScriptHash testNetworkId disputesValidatorHashGY
unindexedAddress = addressFromScriptHash testNetworkId oracleValidatorHashGY

fixtureProtocolParams :: OnchainTypes.ProtocolParams
fixtureProtocolParams =
  OnchainTypes.ProtocolParams
    { OnchainTypes.profilesValidatorScriptHash = profilesValidatorHashPlutus,
      OnchainTypes.attestationsValidatorScriptHash = attestationsValidatorHashPlutus,
      OnchainTypes.disputesValidatorScriptHash = disputesValidatorHashPlutus,
      OnchainTypes.oracleToken = fakeAC "oracle"
    }

fakeAC :: BuiltinByteString -> AssetClass
fakeAC name = AssetClass (CurrencySymbol "", TokenName name)

fixtureMetadata :: MetadataFields
fixtureMetadata = Metadata222 "a name" "a description" "ipfs://QmFixture"

-- | A profile datum naming @claimedId@ as its own id.
profileDatum :: GYAssetClass -> Maybe Credential -> GYDatum
profileDatum claimedId credential =
  datumFromPlutusData
    ( mkCIP68Datum
        OnchainTypes.OnchainProfile
          { OnchainTypes.profileId = assetClassToPlutus claimedId,
            OnchainTypes.profileKind = OnchainTypes.PersonDRep,
            OnchainTypes.profileCredential = credential,
            OnchainTypes.protocolParams = fixtureProtocolParams
          }
        fixtureMetadata
        []
    )

attestationDatum :: GYAssetClass -> GYDatum
attestationDatum claimedId =
  datumFromPlutusData
    ( mkCIP68Datum
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus claimedId,
            OnchainTypes.attestationIssuer = assetClassToPlutus acProfileA,
            OnchainTypes.attestationSubject = assetClassToPlutus acProfileB,
            OnchainTypes.attestationKind = OnchainTypes.Endorsement,
            OnchainTypes.attestationDate = POSIXTime 1700000000000,
            OnchainTypes.attestationPeriod = Nothing,
            OnchainTypes.attestationIsAccepted = True
          }
        fixtureMetadata
        []
    )

disputeDatum :: GYAssetClass -> GYDatum
disputeDatum claimedId =
  datumFromPlutusData
    ( mkCIP68Datum
        OnchainTypes.OnchainDispute
          { OnchainTypes.disputeId = assetClassToPlutus claimedId,
            OnchainTypes.disputeTarget = assetClassToPlutus acAttestation,
            OnchainTypes.disputeOpenedBy = assetClassToPlutus acProfileB,
            OnchainTypes.disputeOpenedAt = POSIXTime 1700000001000,
            OnchainTypes.disputeDeposit = 5_000_000,
            OnchainTypes.disputeDepositTo = Address (PubKeyCredential (PubKeyHash "")) Nothing,
            OnchainTypes.disputeOracleToken = fakeAC "oracle",
            OnchainTypes.disputeVerdict = Nothing
          }
        fixtureMetadata
        []
    )

-- | 2 ADA and nothing else: the free forgery, and the min-UTxO a planted output needs.
dustOnly :: GYValue
dustOnly = valueFromLovelace 2_000_000

-- | 2 ADA plus one named NFT: what an authentic protocol output holds.
withToken :: GYAssetClass -> GYValue
withToken a = valueSingleton a 1 <> dustOnly

fixtureTxId :: GYTxId
fixtureTxId = maybe (error "bad tx-id fixture") id (txIdFromHex (replicate 64 '0'))

atlasMatch :: GYAddress -> GYDatum -> GYValue -> AtlasMatch
atlasMatch addr d v =
  AtlasMatch
    { amTransactionIndex = 0,
      amTransactionId = fixtureTxId,
      amOutputIndex = 0,
      amAddress = addr,
      amValue = v,
      amDatum = GYOutDatumInline d,
      amScriptHash = Nothing,
      amCreatedAt = unsafeSlotFromInteger 100,
      amCreatedAtHeaderHash = "hdr",
      amSpentAt = Nothing,
      amSpentAtHeaderHash = Nothing,
      amSpentAtTransactionId = Nothing,
      amSpentAtInputIndex = Nothing,
      amSpentAtRedeemer = Nothing
    }

------------------------------------------------------------------------------------------------

-- * Running the projection

------------------------------------------------------------------------------------------------

-- | The projection's verdict as a name, rather than an 'Eq' on 'ChainEventProjection' — 'NoEvent'
-- carries an 'AtlasMatch', which has no 'Eq'. Total, so @-Wincomplete-patterns@ catches a new arm.
eventName :: ChainEventProjection -> String
eventName (ProfileEvent _ _) = "profile"
eventName (AttestationEvent _) = "attestation"
eventName (DisputeEvent _) = "dispute"
eventName (NoEvent _) = "none"

project :: AtlasMatch -> ChainEventProjection
project am =
  either
    (error . ("projection threw: " <>) . show)
    id
    (runExcept (projectChainEvent testNetworkId ourPolicy am))

projectName :: AtlasMatch -> String
projectName = eventName . project

------------------------------------------------------------------------------------------------

-- * Kupo fixtures, for the storage and replay half

------------------------------------------------------------------------------------------------

-- | The inverse of 'Palmares.ChainSync.KupoAtlas.kupoDatumToGYDatum': hex-encoded CBOR, which is
-- what Kupo serves for an inline datum.
datumHex :: GYDatum -> Text
datumHex = TE.decodeUtf8 . B16.encode . Api.serialiseToCBOR . datumToApi'

kupoValueOf :: GYValue -> KupoValue
kupoValueOf v =
  KupoValue
    { coins = valueAssetClass v GYLovelace,
      assets = Map.fromList [(assetKey a, n) | (a, n) <- valueToList v, a /= GYLovelace]
    }
  where
    assetKey (GYToken pid tn) = mintingPolicyIdToText pid <> "." <> tokenNameToHex tn
    assetKey GYLovelace = error "unreachable: lovelace filtered above"

-- | A raw match with a real address and a real inline datum. @txid@ varies per fixture because
-- @UniqueKupoMatch@ is @(slot, header, txId, outputIndex)@.
--
-- The tag is LEFT-PADDED to 64 hex characters, because a Cardano transaction id is 32 bytes and
-- @txIdFromHex@ refuses anything shorter. A two-character tag was accepted by every pure assertion
-- here and then dropped by the projection with "conversion error: Invalid transaction ID" — which
-- the ingestion path logs and swallows, so four Pg-backed cases reported zero projected rows and
-- looked like an authentication failure rather than a bad fixture. The padding keeps the call sites
-- readable and the ids real at the same time.
kupoMatch :: Integer -> Text -> GYAddress -> GYDatum -> GYValue -> KupoMatch
kupoMatch slot txid addr d v =
  KupoMatch
    { transaction_index = 0,
      transaction_id = T.justifyRight 64 '0' txid,
      output_index = 0,
      address = addressToText addr,
      value = kupoValueOf v,
      datum_hash = Nothing,
      datum_type = Just "inline",
      datum = Just (datumHex d),
      script_hash = Nothing,
      created_at = CreatedAt slot "hdr",
      spent_at = Nothing
    }

-- | Two profiles claiming one credential, an attestation, a dispute against it — and one planted
-- profile output with a well-formed datum and no protocol token, which must leave no row behind.
fixtureMatches :: [KupoMatch]
fixtureMatches =
  [ kupoMatch 100 "aa" profilesAddress (profileDatum acProfileA (Just testCredential)) (withToken acProfileA),
    kupoMatch 220 "bb" profilesAddress (profileDatum acProfileB (Just testCredential)) (withToken acProfileB),
    kupoMatch 300 "cc" attestationsAddress (attestationDatum acAttestation) (withToken acAttestation),
    kupoMatch 400 "dd" disputesAddress (disputeDatum acDispute) (withToken acDispute),
    kupoMatch 500 "ee" profilesAddress (profileDatum acProfileC Nothing) dustOnly
  ]

fixtureAddresses :: [Text]
fixtureAddresses = map address fixtureMatches

applyAll :: ConnectionPool -> [KupoMatch] -> IO ()
applyAll pool = runAttest pool . mapM_ (putMatchAndProjections testNetworkId ourPolicy)

-- | Every projection row, as text, order-independent. @show@ of the entity VALUE and not the
-- 'Entity': a replay re-inserts the rows and the serial keys legitimately change.
projectionSnapshot :: ConnectionPool -> IO [String]
projectionSnapshot pool =
  runAttest pool $ do
    ps <- selectList ([] :: [Filter ProfileProjection]) []
    as <- selectList ([] :: [Filter AttestationProjection]) []
    ds <- selectList ([] :: [Filter DisputeProjection]) []
    pure (sort (map (show . entityVal) ps <> map (show . entityVal) as <> map (show . entityVal) ds))

freshDb :: (ConnectionPool -> IO a) -> IO a
freshDb body = withScratchDb $ \pool -> do
  runPg pool ensureAttestSchema
  runAttest pool runMigrations
  body pool

------------------------------------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "projections"
    [ testGroup "authentication at the projection (inherited fix #3)" authenticationTests,
      testGroup "rollback replays projections, not only raw rows" replayTests
    ]

authenticationTests :: [TestTree]
authenticationTests =
  [ -- THE case that fails on the old behaviour: a well-formed profile datum at the profiles
    -- address, 2 ADA, no protocol token. Before the fix this returned "profile".
    testCase "a UTxO at the profiles address WITHOUT the named token projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA Nothing) dustOnly) @?= "none",
    testCase "a UTxO at the profiles address WITH its named token projects a profile" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA Nothing) (withToken acProfileA))
        @?= "profile",
    testCase "a token whose name does not match the datum's own id projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA Nothing) (withToken acProfileB))
        @?= "none",
    testCase "the datum's own id under somebody else's policy projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acForeign Nothing) (withToken acForeign))
        @?= "none",
    testCase "two copies of the named token projects nothing — the id is an NFT or it is not ours" $
      projectName
        (atlasMatch profilesAddress (profileDatum acProfileA Nothing) (valueSingleton acProfileA 2 <> dustOnly))
        @?= "none",
    testCase "an attestation UTxO without its token projects nothing" $
      projectName (atlasMatch attestationsAddress (attestationDatum acAttestation) dustOnly) @?= "none",
    testCase "an attestation UTxO with its token projects an attestation" $
      projectName (atlasMatch attestationsAddress (attestationDatum acAttestation) (withToken acAttestation))
        @?= "attestation",
    testCase "a dispute UTxO without its token projects nothing" $
      projectName (atlasMatch disputesAddress (disputeDatum acDispute) dustOnly) @?= "none",
    testCase "a dispute UTxO projects a DisputeProjection with its target and verdict" $
      case project (atlasMatch disputesAddress (disputeDatum acDispute) (withToken acDispute)) of
        DisputeEvent d -> (pdDisputeId d, pdTarget d, pdVerdict d) @?= (acDispute, acAttestation, Nothing)
        other -> assertFailure ("expected a dispute, got " <> eventName other),
    testCase "an authentic profile UTxO at an address we do not index projects nothing" $
      projectName (atlasMatch unindexedAddress (profileDatum acProfileA Nothing) (withToken acProfileA))
        @?= "none",
    testCase "a spent UTxO projects nothing even when it authenticates" $
      let m = atlasMatch profilesAddress (profileDatum acProfileA Nothing) (withToken acProfileA)
       in projectName m {amSpentAt = Just (unsafeSlotFromInteger 101)} @?= "none",
    testCase "a profile projection carries the claimed credential, in its CIP-129 rendering" $
      case project (atlasMatch profilesAddress (profileDatum acProfileA (Just testCredential)) (withToken acProfileA)) of
        ProfileEvent p credential ->
          (profileId p, credential) @?= (acProfileA, Just (claimCredentialToText testCredential))
        other -> assertFailure ("expected a profile, got " <> eventName other),
    testCase "a profile that claims no credential projects no credential" $
      case project (atlasMatch profilesAddress (profileDatum acProfileA Nothing) (withToken acProfileA)) of
        ProfileEvent _ credential -> credential @?= Nothing
        other -> assertFailure ("expected a profile, got " <> eventName other)
  ]

replayTests :: [TestTree]
replayTests =
  [ -- Why the inherited replay test was vacuous: its fixture address could never convert, so every
    -- match took the error branch and no projection was ever built to rebuild.
    testCase "the fixture addresses are real addresses, so the replay takes the success branch" $
      all (isJust . addressFromTextMaybe) fixtureAddresses @?= True,
    testCase "a rollback and replay rebuilds the projections byte-identically" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        before <- projectionSnapshot pool
        assertBool "there are projections to lose" (not (null before))
        -- Above every fixture slot, so nothing is discarded: what this measures is the wipe + replay.
        runAttest pool (rollbackTo testNetworkId ourPolicy 1000)
        after <- projectionSnapshot pool
        after @?= before,
    testCase "a rollback below a projection's slot drops it, and the survivors are rebuilt" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        before <- projectionSnapshot pool
        -- Below the attestation (300) and the dispute (400), above both profiles (100, 220).
        runAttest pool (rollbackTo testNetworkId ourPolicy 250)
        after <- projectionSnapshot pool
        assertBool "the rollback actually dropped something" (length after < length before)
        profiles <- runAttest pool (selectList ([] :: [Filter ProfileProjection]) [])
        disputes <- runAttest pool (selectList ([] :: [Filter DisputeProjection]) [])
        (length profiles, length disputes) @?= (2, 0),
    testCase "replaying twice is idempotent at the projection level, not only the match level" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        one <- projectionSnapshot pool
        applyAll pool fixtureMatches
        two <- projectionSnapshot pool
        two @?= one,
    -- Fix #3 end to end: the planted output stays in the raw log (the replay source must be
    -- complete) and reaches no projection table (the read API must never see it).
    testCase "the planted UTxO is kept as a raw match and projected nowhere" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        raw <- runAttest pool (selectList ([] :: [Filter OnchainMatchEvent]) [])
        profiles <- runAttest pool (selectList ([] :: [Filter ProfileProjection]) [])
        (length raw, length profiles) @?= (length fixtureMatches, 2),
    -- Review Focus item 2: a credential may be claimed twice, and both claims must stay visible.
    testCase "a profile projection carries the claimed credential, and two claims coexist" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        claimants <-
          runAttest
            pool
            ( selectList
                [ProfileProjectionProfileCredential ==. Just (claimCredentialToText testCredential)]
                [Asc ProfileProjectionCreatedAtSlot]
            )
        map (profileProjectionProfileId . entityVal) claimants @?= [acProfileA, acProfileB]
  ]
