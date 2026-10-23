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
import Database.Persist (Entity (..), Filter, SelectOpt (Asc), getBy, selectList, (==.))
import Database.Persist.Sql (ConnectionPool, rawExecute)
import GeniusYield.Types
import Palmares.ChainSync.KupoAtlas (AtlasMatch (..), toGYAssetClass)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..), KupoValue (..))
import Palmares.DomainTypes.Core.Types (Attestation (..), AttestationType (CredentialClaim))
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

acClaimRecord, acWithdrawRecord :: GYAssetClass
acClaimRecord = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0f8"
acWithdrawRecord = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0f9"

-- | A second credential, for the case a withdrawal names one the profile does not publish.
otherCredential :: OnchainTypes.ClaimedCredential
otherCredential = OnchainTypes.ClaimedDRep (PubKeyCredential (PubKeyHash "fedcba9876543210fedcba987654"))

acOracle :: GYAssetClass
acOracle = ac "c0ffee00000000000000000000000000000000000000000000000001.000643b0f7"

-- | The credential two of the profiles below both claim — Review Focus item 2.
-- | ADR 0006: a claim names the credential AND the role, so the fixture is the claimed form.
testCredential :: OnchainTypes.ClaimedCredential
testCredential = OnchainTypes.ClaimedDRep (PubKeyCredential (PubKeyHash "0123456789abcdef0123456789ab"))

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
profileDatum :: GYAssetClass -> GYDatum
profileDatum claimedId =
  datumFromPlutusData
    ( mkCIP68Datum
        OnchainTypes.OnchainProfile
          { OnchainTypes.profileId = assetClassToPlutus claimedId,
            OnchainTypes.profileKind = OnchainTypes.PersonDRep,
            OnchainTypes.profileOracleToken = OnchainTypes.oracleToken fixtureProtocolParams
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
            OnchainTypes.attestationIsAccepted = True,
            -- Any value: the projection drops this field, which is the point of asserting the
            -- projected shape below rather than the datum's.
            OnchainTypes.attestationOracleToken = assetClassToPlutus acOracle,
            OnchainTypes.attestationCredential = Nothing
          }
        fixtureMetadata
        []
    )

-- | A 'CredentialClaim' record: self-issued, so subject and issuer are the same profile — which is
-- what @Mc1@ requires on chain and what the derivation below reads the subject from.
credentialRecordDatum :: OnchainTypes.AttestationKind -> GYAssetClass -> GYAssetClass -> OnchainTypes.ClaimedCredential -> GYDatum
credentialRecordDatum kind recordId subjectProfile credential =
  datumFromPlutusData
    ( mkCIP68Datum
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus recordId,
            OnchainTypes.attestationIssuer = assetClassToPlutus subjectProfile,
            OnchainTypes.attestationSubject = assetClassToPlutus subjectProfile,
            OnchainTypes.attestationKind = kind,
            OnchainTypes.attestationDate = POSIXTime 1700000000000,
            OnchainTypes.attestationPeriod = Nothing,
            OnchainTypes.attestationIsAccepted = False,
            OnchainTypes.attestationOracleToken = assetClassToPlutus acOracle,
            OnchainTypes.attestationCredential = Just credential
          }
        fixtureMetadata
        []
    )

credentialClaimDatum :: GYAssetClass -> OnchainTypes.ClaimedCredential -> GYDatum
credentialClaimDatum recordId = credentialRecordDatum OnchainTypes.CredentialClaim recordId acProfileA

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
            OnchainTypes.disputeStaleAfter = POSIXTime (1700000001000 + 2592000000),
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
eventName (ProfileEvent _) = "profile"
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
  [ kupoMatch 100 "aa" profilesAddress (profileDatum acProfileA) (withToken acProfileA),
    kupoMatch 220 "bb" profilesAddress (profileDatum acProfileB) (withToken acProfileB),
    kupoMatch 300 "cc" attestationsAddress (attestationDatum acAttestation) (withToken acAttestation),
    kupoMatch 400 "dd" disputesAddress (disputeDatum acDispute) (withToken acDispute),
    kupoMatch 500 "ee" profilesAddress (profileDatum acProfileC) dustOnly
  ]

fixtureAddresses :: [Text]
fixtureAddresses = map address fixtureMatches

-- | What the read layer publishes as a profile's credential. 'Nothing' means no row at all, which
-- is a different answer from a row whose column is null — and the derivation tests need to tell
-- those apart.
credentialOf :: ConnectionPool -> GYAssetClass -> IO (Maybe (Maybe Text))
credentialOf pool pid =
  runAttest pool $
    fmap (profileProjectionProfileCredential . entityVal) <$> getBy (UniqueProfileProjection pid)

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
      testGroup "rollback replays projections, not only raw rows" replayTests,
      cs01IsolationTests
    ]

authenticationTests :: [TestTree]
authenticationTests =
  [ -- THE case that fails on the old behaviour: a well-formed profile datum at the profiles
    -- address, 2 ADA, no protocol token. Before the fix this returned "profile".
    testCase "a UTxO at the profiles address WITHOUT the named token projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA) dustOnly) @?= "none",
    testCase "a UTxO at the profiles address WITH its named token projects a profile" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA) (withToken acProfileA))
        @?= "profile",
    testCase "a token whose name does not match the datum's own id projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acProfileA) (withToken acProfileB))
        @?= "none",
    testCase "the datum's own id under somebody else's policy projects nothing" $
      projectName (atlasMatch profilesAddress (profileDatum acForeign) (withToken acForeign))
        @?= "none",
    testCase "two copies of the named token projects nothing — the id is an NFT or it is not ours" $
      projectName
        (atlasMatch profilesAddress (profileDatum acProfileA) (valueSingleton acProfileA 2 <> dustOnly))
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
      projectName (atlasMatch unindexedAddress (profileDatum acProfileA) (withToken acProfileA))
        @?= "none",
    testCase "a spent UTxO projects nothing even when it authenticates" $
      let m = atlasMatch profilesAddress (profileDatum acProfileA) (withToken acProfileA)
       in projectName m {amSpentAt = Just (unsafeSlotFromInteger 101)} @?= "none",
    -- ADR 0003 moved the binding off the profile datum, so a PROFILE event no longer has a
    -- credential to carry. The two cases that asserted it are replaced by one that asserts where it
    -- lives now, and by the DB-backed derivation tests further down — which are the real coverage,
    -- because the derivation is the part that is new rather than moved.
    testCase "a credential claim projects with its credential, in its CIP-129 rendering" $
      case project (atlasMatch attestationsAddress (credentialClaimDatum acAttestation testCredential) (withToken acAttestation)) of
        AttestationEvent a ->
          (attestationKind a, attestationCredential a)
            @?= (CredentialClaim, Just (claimCredentialToText testCredential))
        other -> assertFailure ("expected an attestation, got " <> eventName other)
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
    -- __ADR 0003: the derivation, which is the only part of this change that is new rather than
    -- moved.__ `profile_credential` is no longer read off the profile datum; it is computed from the
    -- credential records. Three things have to hold and none of them would fail loudly on their own:
    -- a claim sets it, a withdrawal naming the SAME credential clears it, and a withdrawal naming a
    -- different one changes nothing — the last because the chain permits such a record (@Mc3@ asks
    -- only the named credential to consent), so the read layer is what has to ignore it.
    testCase "a credential claim sets the profile's published credential, and the matching withdrawal clears it" $
      freshDb $ \pool -> do
        applyAll pool [kupoMatch 100 "aa" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        unbound <- credentialOf pool acProfileA
        applyAll pool [kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord)]
        bound <- credentialOf pool acProfileA
        applyAll pool [kupoMatch 700 "1a" attestationsAddress (credentialRecordDatum OnchainTypes.CredentialWithdrawal acWithdrawRecord acProfileA testCredential) (withToken acWithdrawRecord)]
        withdrawn <- credentialOf pool acProfileA
        (unbound, bound, withdrawn)
          @?= (Just Nothing, Just (Just (claimCredentialToText testCredential)), Just Nothing),
    testCase "a withdrawal naming a credential the profile does not publish changes nothing" $
      freshDb $ \pool -> do
        applyAll pool [kupoMatch 100 "aa" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        applyAll pool [kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord)]
        applyAll pool [kupoMatch 700 "1a" attestationsAddress (credentialRecordDatum OnchainTypes.CredentialWithdrawal acWithdrawRecord acProfileA otherCredential) (withToken acWithdrawRecord)]
        credentialOf pool acProfileA >>= (@?= Just (Just (claimCredentialToText testCredential))),
    -- The hazard `putProfileProjection` carries a paragraph about: `upsertByUnique` REPLACES the
    -- whole row, so a profile event that wrote the credential column would erase a binding every
    -- time the profile's metadata changed. A later profile match is exactly that event.
    testCase "a later profile match does not erase a binding the attestations established" $
      freshDb $ \pool -> do
        applyAll pool [kupoMatch 100 "aa" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        applyAll pool [kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord)]
        applyAll pool [kupoMatch 800 "2b" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        credentialOf pool acProfileA >>= (@?= Just (Just (claimCredentialToText testCredential))),
    -- __The order every one of the three cases above missed, and the one a re-sync produces.__
    -- 'projectChainEvent' emits nothing for a SPENT output, so a profile that was updated after it
    -- claimed is replayed only at its latest UTxO's slot — ABOVE the claim's. The claim therefore
    -- arrives when no profile row exists at all, and the first version of this derivation wrote it
    -- with `updateWhere`, which matches no row and says nothing. `currentSchemaVersion` 3 -> 4 makes
    -- this re-sync the upgrade path for every deployed database, so the loss would have been the
    -- normal case rather than an edge one. Found by an audit reconciliation; no test had this shape.
    testCase "a claim that replays before any profile row still binds (the re-sync order)" $
      freshDb $ \pool -> do
        applyAll pool [kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord)]
        applyAll pool [kupoMatch 800 "2b" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        credentialOf pool acProfileA >>= (@?= Just (Just (claimCredentialToText testCredential))),
    -- And the fold really is a fold, not "the last claim wins": a withdrawal that also precedes the
    -- profile row has to cancel the claim that precedes it.
    testCase "a claim and its withdrawal both replaying before the profile row leave it unbound" $
      freshDb $ \pool -> do
        applyAll pool [kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord)]
        applyAll pool [kupoMatch 700 "1a" attestationsAddress (credentialRecordDatum OnchainTypes.CredentialWithdrawal acWithdrawRecord acProfileA testCredential) (withToken acWithdrawRecord)]
        applyAll pool [kupoMatch 800 "2b" profilesAddress (profileDatum acProfileA) (withToken acProfileA)]
        credentialOf pool acProfileA >>= (@?= Just Nothing),
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
    --
    -- Two CLAIM RECORDS now, not two profile datums (ADR 0003) — and the query is the same one a
    -- reader would run, so what it pins is that the derivation sets the column on BOTH profiles
    -- rather than treating a credential as something only one profile may hold. The chain does not
    -- enforce uniqueness and the read layer must not invent it.
    testCase "two profiles may hold a binding to one credential, and the read layer shows both" $
      freshDb $ \pool -> do
        applyAll pool fixtureMatches
        applyAll
          pool
          [ kupoMatch 600 "ff" attestationsAddress (credentialClaimDatum acClaimRecord testCredential) (withToken acClaimRecord),
            kupoMatch 610 "3c" attestationsAddress (credentialRecordDatum OnchainTypes.CredentialClaim acWithdrawRecord acProfileB testCredential) (withToken acWithdrawRecord)
          ]
        claimants <-
          runAttest
            pool
            ( selectList
                [ProfileProjectionProfileCredential ==. Just (claimCredentialToText testCredential)]
                [Asc ProfileProjectionCreatedAtSlot]
            )
        map (profileProjectionProfileId . entityVal) claimants @?= [acProfileA, acProfileB]
  ]

-------------------------------------------------------------------------------------------------

-- * CS-01, second half — one bad row must not stop the projector

-------------------------------------------------------------------------------------------------

-- | The isolation `applyMatches` does when a window's single transaction aborts.
--
-- __What this is about.__ A window used to be applied in ONE transaction, so any row Postgres
-- refused aborted the batch: nothing landed, the persisted cursor never advanced, and the fetch loop
-- retries only Kupo client errors. One hand-built attestation for about 1.3 ADA stopped the read
-- layer permanently. The first half of `CS-01` removed the one datum value that could do it; this is
-- about the shape that let any value do it.
--
-- __The poison is infrastructural on purpose.__ Contriving a datum that still defeats every guard
-- would mean re-finding what the first half closed. Dropping `profile_projection` is a real,
-- deterministic failure of the same CLASS — a write Postgres refuses, mid-window — and it exercises
-- exactly the code path: batch aborts, isolation runs per match, each failure is dead-lettered, and
-- the function RETURNS instead of throwing, which is what lets the cursor advance.
cs01IsolationTests :: TestTree
cs01IsolationTests =
  testGroup
    "CS-01 second half — a window survives a row Postgres refuses"
    [ testCase "the batch aborts, every match is dead-lettered, and applyMatches does NOT throw" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          -- The poison: the table the profile projections need is gone, the dead-letter table stays.
          runAttest pool $ rawExecute "DROP TABLE profile_projection" []
          -- No exception escapes. That is the whole point: the caller advances the cursor.
          applyMatches testNetworkId ourPolicy pool fixtureMatches
          dead <- runAttest pool (selectList ([] :: [Filter AttestDeadLetter]) [])
          assertBool "at least the profile matches were dead-lettered" (not (null dead))
          -- Every dead-letter row carries the error that stopped it, so an operator can see why.
          assertBool
            "each row records a non-empty error"
            (all (not . T.null . attestDeadLetterLastError . entityVal) dead),
      -- Re-driving a window that still fails must not grow the table once per tick, so the write is
      -- an upsert on the match's own key.
      testCase "re-driving the same bad window replaces its dead-letter rows rather than adding" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          runAttest pool $ rawExecute "DROP TABLE profile_projection" []
          applyMatches testNetworkId ourPolicy pool fixtureMatches
          first <- runAttest pool (selectList ([] :: [Filter AttestDeadLetter]) [])
          applyMatches testNetworkId ourPolicy pool fixtureMatches
          second <- runAttest pool (selectList ([] :: [Filter AttestDeadLetter]) [])
          length second @?= length first,
      -- And the converse, which keeps the first two honest: with the table present, a clean window
      -- leaves the dead-letter table EMPTY. Without this, "dead-lettered" could mean "always".
      testCase "a window with nothing wrong dead-letters nothing" $
        withScratchDb $ \pool -> do
          runPg pool ensureAttestSchema
          runAttest pool runMigrations
          applyMatches testNetworkId ourPolicy pool fixtureMatches
          dead <- runAttest pool (selectList ([] :: [Filter AttestDeadLetter]) [])
          assertEqual "nothing was dead-lettered" 0 (length dead)
    ]
