-- AllowAmbiguousTypes: `schemaJson`'s return type is `String`, so its `a` is reachable only through
-- a type application at the call site (`schemaJson @ProfileActionType`). That is the point — the
-- thing under test is the TYPE's generated schema, not a value of it.
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The write path's pure contracts: the credential codec, the witness, and the refusals.
--
-- __Why these are unit tests and not emulator tests.__ Everything asserted here is a function of
-- values, so it can be pinned without a provider: the CIP-129 codec, the 'ClaimWitness' mapping, and
-- the error surface a client branches on — its code, its status and the fix in its message. The cases
-- that drive a real refusal through 'Palmares.TxBuilding.Operations.claimProfileTX',
-- @issueAttestationTX@ and @openDisputeTX@ need the CLB harness and belong with T-ATTEST-5's
-- @UnitTests.Profile@ and @UnitTests.Dispute@; the named ones are listed in this module's commit.
--
-- Three of these assertions fail to COMPILE against the pre-T-ATTEST-6 code rather than failing an
-- assertion, which is the honest failure for a signature change: 'parseClaimCredential' and
-- 'ClaimWitness' did not exist, and 'spendWithGivenWitness' cannot be written at all against a
-- 'txMustSpendFromAddress' that takes no witness.
module UnitTests.WritePath (writePathTests, constructorsOf, GConstructorCount) where

import Control.Exception (displayException)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Kind (Type)
import Data.List (isInfixOf, nub)
import Data.Proxy (Proxy (..))
import Data.Swagger (ToSchema, toSchema)
import Data.Text (Text)
import GHC.Generics (C1, D1, Generic (Rep), (:+:))
import GeniusYield.TxBuilder (GYTxQueryMonadIO, GYTxSkeleton)
import GeniusYield.Types
  ( GYAddress,
    GYAssetClass,
    GYPaymentKeyHash,
    GYScriptHash,
    GYSimpleScript (RequireSignature),
    GYTxInWitness (..),
    PlutusVersion (PlutusV3),
    keyHashToRawBytes,
    paymentKeyHashToPlutus,
    pubKeyHashFromPlutus,
    toPubKeyHash,
  )
import Palmares.DomainTypes.Core.Actions (ClaimWitness (..), ProfileActionType)
import Palmares.DomainTypes.Core.Ids (parseCredentialCip129)
import Palmares.Onchain.Protocol.Types (ClaimedCredential (..), claimedCredentialOf)
import Palmares.TxBuilding.Conversions
  ( claimCredentialToText,
    claimWitnessToTxInWitness,
    isScriptCredential,
    parseClaimCredential,
  )
import Palmares.TxBuilding.Exceptions
  ( TxBuildingException (..),
    txBuildingExceptionCode,
    txBuildingExceptionToHttpStatus,
  )
import Palmares.TxBuilding.Skeletons (txMustSpendFromAddress)
import PlutusLedgerApi.V3 (Credential (PubKeyCredential))
import Test.Tasty
import Test.Tasty.HUnit

-- | The witness is a PARAMETER of 'txMustSpendFromAddress', pinned at the type level.
--
-- This binding is the test: it does not type-check against the old signature, which took an asset
-- class and a list of addresses and hardcoded 'GYTxInWitnessKey'. That hardcoding made every
-- script-held user token unspendable by our own off-chain code while the blueprint advertised script
-- issuers, so the parameter is the whole fix and a type is the right place to hold it.
spendWithGivenWitness ::
  GYAssetClass -> [GYAddress] -> GYTxInWitness 'PlutusV3 -> GYTxQueryMonadIO (GYTxSkeleton 'PlutusV3)
spendWithGivenWitness = txMustSpendFromAddress

-- | Is this a plain key witness? Local to the test: nothing in production branches on this.
isKeyWitness :: GYTxInWitness v -> Bool
isKeyWitness GYTxInWitnessKey = True
isKeyWitness _ = False

-- | The "Bitcows" preprod DRep's 28 bytes, in the four renderings this module needs. The same golden
-- vectors @UnitTests.GovIds@ pins the codec with, restated here so the two modules do not share
-- fixtures: these assert what the CLAIM does with them, which is a different contract.
drepKeyBech32, drepScriptBech32, drepCip105, ccColdBech32 :: Text
drepKeyBech32 = "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
drepScriptBech32 = "drep1ywqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmuzqx0"
drepCip105 = "drep1symc604gnd50plqfj393lyljl6u9zvv0r9he3wjq98v2sz3vtkp"
ccColdBech32 = "cc_cold1z2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qlx580v"

-- | A payment key hash, standing in for what @admin operator-address@ derives from the mnemonic.
--
-- 28 bytes, as every Cardano credential hash is — and it is a @GYPaymentKeyHash@ rather than a
-- literal because that is the type the derivation produces and the type @mustBeSignedBy@ consumes.
-- A raw 'ByteString' fixture here would prove the codec and skip exactly the conversion under test.
operatorKeyHash :: GYPaymentKeyHash
operatorKeyHash = "e1cbb80db89e292269aeb93ec15eb963dda5176b66949fe1c2a6a38d"

-- | The DRep id @admin operator-address@ prints for 'operatorKeyHash'.
--
-- Written as the composition the command uses rather than as a literal, because a literal would
-- pin the ENCODER's current output and go on passing if the composition changed — which is the one
-- thing these three cases are about.
-- | The role a claim names, as the HRP that renders it. A tag rather than the constructor so the
-- assertion reads as the identifier a client would see.
roleTag :: ClaimedCredential -> Text
roleTag (ClaimedDRep _) = "drep"
roleTag (ClaimedCCCold _) = "cc_cold"
roleTag (ClaimedCCHot _) = "cc_hot"

operatorDrepId :: Text
operatorDrepId = claimCredentialToText (ClaimedDRep (PubKeyCredential (paymentKeyHashToPlutus operatorKeyHash)))

scriptHashA :: GYScriptHash
scriptHashA = "cabdd19b58d4299fde05b53c2c0baf978bf9ade734b490fc0cc8b7d0"

nativeScriptA :: GYSimpleScript
nativeScriptA = RequireSignature "e1cbb80db89e292269aeb93ec15eb963dda5176b66949fe1c2a6a38a"

-- | The JSON of a type's generated Swagger schema, as a string to search.
schemaJson :: forall a. (ToSchema a) => String
schemaJson = BL8.unpack (encode (toSchema (Proxy :: Proxy a)))

-------------------------------------------------------------------------------

-- * How many constructors a type has, from its own 'Generic' representation

-------------------------------------------------------------------------------

-- | Count the constructors of a sum type.
--
-- __Why this exists, in six lines, in a test module.__ This repository pins sum types with
-- hand-written lists of one value per constructor, and has been bitten by that twice in two weeks:
-- @PropertyTests.allAdminActions@ carries a comment saying so verbatim (\"this list IS the test, so
-- an action missing from it is an index mirror and an apply mirror that quietly say nothing\" — D-A
-- added 'Palmares.DomainTypes.Core.Actions.SetDisputeTimeoutAction' and nothing noticed), and
-- @UnitTests.InteractionApi@'s own @disputeArms@ called itself \"one value per constructor\" while
-- missing @ExpireDisputeAction@.
--
-- A count read off 'Rep' cannot be forgotten: GHC derives it, so a new constructor changes this
-- number the moment it is written, and the test that compares it against the list's length fails
-- before anybody runs the service. That is the difference between a list that documents a trap and
-- a list that is checked.
--
-- Three instances is the whole mechanism: a sum splits, a constructor counts one, the datatype
-- wrapper passes through. Fields are never visited, so a constructor carrying arguments costs
-- nothing — which is the case 'Enum'\/'Bounded' cannot serve, and the reason this exists at all.
--
-- The kind is written out rather than inferred: the class variable appears in no method type, so
-- nothing in the declaration would otherwise pin it to the kind 'Rep' has.
class GConstructorCount (f :: Type -> Type) where
  gConstructorCount :: Int

instance (GConstructorCount a, GConstructorCount b) => GConstructorCount (a :+: b) where
  gConstructorCount = gConstructorCount @a + gConstructorCount @b

instance GConstructorCount (C1 meta f) where
  gConstructorCount = 1

instance (GConstructorCount f) => GConstructorCount (D1 meta f) where
  gConstructorCount = gConstructorCount @f

-- | The number of constructors of @a@, e.g. @constructorsOf \@TxBuildingException@.
constructorsOf :: forall a. (Generic a, GConstructorCount (Rep a)) => Int
constructorsOf = gConstructorCount @(Rep a)

-------------------------------------------------------------------------------

-- * The published error table

-------------------------------------------------------------------------------

-- | Every 'TxBuildingException', with the status and the code the write API publishes for it.
--
-- __This is the table the audit asked for, and it is a second, independent spelling of
-- 'txBuildingExceptionToHttpStatus' on purpose.__ A test that recomputed the status from the
-- function it is checking would pass on whatever that function happened to return. MEASURED before
-- this list existed: of the 26 constructors, five had their status or their code asserted anywhere
-- in the suite and thirteen were not named in it at all — while twelve reached a client through a
-- @_ = 400@ in the mapping. So the published answer for most of this type was a value nobody had
-- chosen and nothing could contradict.
--
-- The @code@ column is spelled out rather than derived from 'show', for the same reason: the code is
-- what a client branches on and what the docs tables in @docs\/usecases@ list, so it is a published
-- name and a rename of the constructor is a BREAKING change that has to show up here.
--
-- Rows are in the order the constructors are declared, so this list and the data declaration diff
-- against each other by eye.
publishedErrorTable :: [(TxBuildingException, Int, String)]
publishedErrorTable =
  [ (ProfileNotFound, 404, "ProfileNotFound"),
    (WrongProfileType, 400, "WrongProfileType"),
    (AttestationNotFound, 404, "AttestationNotFound"),
    (AttestationAlreadyAccepted, 400, "AttestationAlreadyAccepted"),
    (AttestationOtherMetadataReservedKeys, 400, "AttestationOtherMetadataReservedKeys"),
    (AttestationPeriodInverted, 400, "AttestationPeriodInverted"),
    (DepositAddressNotSpendable, 400, "DepositAddressNotSpendable"),
    (DepositAddressIsScript, 400, "DepositAddressIsScript"),
    (SubjectProfileNotFound, 404, "SubjectProfileNotFound"),
    (CredentialMalformed, 400, "CredentialMalformed"),
    -- The one constructor that carries a field, and the one whose code could have been wrong without
    -- anybody noticing: `txBuildingExceptionCode` is `takeWhile (/= ' ') . show`, so an applied
    -- constructor's code is the constructor name and NOT the rendered script hash beside it.
    (ScriptCredentialHasNoUtxo scriptHashA, 400, "ScriptCredentialHasNoUtxo"),
    (DisputeNotFound, 404, "DisputeNotFound"),
    (DisputeAlreadyOpen, 400, "DisputeAlreadyOpen"),
    (DisputeAlreadyResolved, 400, "DisputeAlreadyResolved"),
    (DisputeVerdictNotAFinding, 400, "DisputeVerdictNotAFinding"),
    (AttestationKindIsCredentialBinding, 400, "AttestationKindIsCredentialBinding"),
    (DisputeNotStaleYet, 400, "DisputeNotStaleYet"),
    (OracleNotFound, 404, "OracleNotFound"),
    -- 500 and not 400: an oracle UTxO whose datum this protocol wrote and cannot now parse is a
    -- fault on our side of the boundary, and there is nothing the caller can change about it. Same
    -- for `DatumParseError` below.
    (OracleDatumInvalid, 500, "OracleDatumInvalid"),
    (ProtocolPaused, 503, "ProtocolPaused"),
    (DeployedScriptsNotReady, 503, "DeployedScriptsNotReady"),
    (InvalidAssetClass, 400, "InvalidAssetClass"),
    (NFTNotFound, 404, "NFTNotFound"),
    (MultipleUtxosFound, 400, "MultipleUtxosFound"),
    (DatumParseError, 500, "DatumParseError"),
    (NoDustFound, 404, "NoDustFound")
  ]

writePathTests :: TestTree
writePathTests =
  testGroup
    "the write path"
    [ -- Review Focus item 1: the refusal must be clean and must carry the workaround. A Plutus script
      -- that only votes or withdraws holds no UTxO at its own address, so it cannot prove control in
      -- one transaction — and the fix is one transaction, which is the only thing the error can
      -- usefully say. The build-path half (the lookup happening BEFORE the balancer) is the emulator's.
      testCase "a script credential with no UTxO at its own address is refused, with the fix in the message" $
        assertBool
          "the message says how to fix it"
          ("send a UTxO to that script address" `isInfixOf` displayException (ScriptCredentialHasNoUtxo scriptHashA)),
      -- The code is what a client branches on, and this constructor carries a field — so the code is
      -- exactly the trap: `show` of an applied constructor includes the argument. It must not.
      testCase "the error code of a refusal that carries a script hash is still just the code" $
        ( txBuildingExceptionCode (ScriptCredentialHasNoUtxo scriptHashA),
          txBuildingExceptionToHttpStatus (ScriptCredentialHasNoUtxo scriptHashA)
        )
          @?= ("ScriptCredentialHasNoUtxo", 400),
      testCase "a malformed credential is refused before any chain query" $
        parseClaimCredential "drep1notabech32" @?= Left CredentialMalformed,
      -- CIP-129 both ways, because the claim's whole point is that the header byte is not thrown away.
      testCase "a CIP-129 drep id round-trips to a key credential and back" $
        (claimCredentialToText <$> parseClaimCredential drepKeyBech32) @?= Right drepKeyBech32,
      testCase "a CIP-129 SCRIPT drep id parses to a script credential, not a key one" $
        (isScriptCredential . claimedCredentialOf <$> parseClaimCredential drepScriptBech32) @?= Right True,
      testCase "a CIP-129 key drep id parses to a key credential" $
        (isScriptCredential . claimedCredentialOf <$> parseClaimCredential drepKeyBech32) @?= Right False,
      -- ADR 0006, AND THE WHOLE POINT OF IT. The three identifier families carry the same 28 bytes
      -- and differ only in CIP-129's header byte, so a parser that dropped the role made all three
      -- indistinguishable — and the renderer then published every claim as `drep1…`. These pin the
      -- role surviving the round trip, which is the defect `OC-04` reported.
      testCase "the ROLE survives: a drep id claims as a DRep" $
        (roleTag <$> parseClaimCredential drepKeyBech32) @?= Right "drep",
      testCase "the ROLE survives: a cc_cold id claims as committee cold, not as a DRep" $
        (roleTag <$> parseClaimCredential ccColdBech32) @?= Right "cc_cold",
      testCase "a committee cold claim renders back as cc_cold, not as drep of the same bytes" $
        (claimCredentialToText <$> parseClaimCredential ccColdBech32) @?= Right ccColdBech32,
      -- The regression in one line: same 28 bytes, two roles, two identifiers. Before ADR 0006 both
      -- sides of this were `drep1…` and the assertion could not be written.
      testCase "the same bytes under two roles render to two different identifiers" $
        ( claimCredentialToText . ClaimedDRep . claimedCredentialOf <$> parseClaimCredential ccColdBech32
        )
          @?= Right drepKeyBech32,
      -- What @admin operator-address@ prints as ATTEST_SMOKE_DREP_ID. A test suite cannot import an
      -- executable's modules, so these pin the library composition and NOT the line in
      -- @admin/Main.hs@ that calls it: a change there to `drepIdCip105` would still be green here.
      --
      -- A THIRD CASE STOOD HERE AND WAS DELETED, because it could not fail on its own:
      -- @parseClaimCredential operatorDrepId == Right (PubKeyCredential (paymentKeyHashToPlutus
      -- operatorKeyHash))@ has `paymentKeyHashToPlutus operatorKeyHash` on both sides — the
      -- right-hand side IS how `operatorDrepId` is built — so it cancels and reduces to
      -- @parseClaimCredential . claimCredentialToText == Right@ on one value. That is codec
      -- self-consistency, which the golden-vector round-trip above already pins more strongly: a
      -- self-consistent but WRONG codec passes the cancelled version and fails the golden one. A
      -- fourth, @isScriptCredential … == Right False@, was deleted for being implied by the first
      -- (a `Right (PubKeyCredential _)` is not a script by definition) and already pinned on a
      -- vector above.
      --
      -- The 28 bytes the id carries must be the key hash's OWN bytes, because the transaction
      -- requires `mustBeSignedBy <that hash>`. A round-trip cannot see this: it would still hold if
      -- the rendering hashed the key a second time, as long as the parse undid it.
      testCase "the id carries the signing key's own 28 bytes, not a rehash of them" $
        (snd <$> parseCredentialCip129 operatorDrepId) @?= Just (keyHashToRawBytes operatorKeyHash),
      -- The loop closed along the PRODUCTION path, which is what the deleted case was reaching for
      -- and missing. `claimProofSkeleton`'s key arm does `pubKeyHashFromPlutus'` on the parsed
      -- credential and feeds the result to `mustBeSignedBy`; this runs that same conversion and
      -- compares against the key the wallet actually holds. So: printed id -> what the API parses
      -- -> what the builder requires a signature from -> the operator's own key.
      testCase "the printed id resolves, by the builder's own conversion, to the key that signs" $
        ( case parseClaimCredential operatorDrepId of
            Right (ClaimedDRep (PubKeyCredential pkh)) -> either (const Nothing) Just (pubKeyHashFromPlutus pkh)
            _ -> Nothing
        )
          @?= Just (toPubKeyHash operatorKeyHash),
      -- The judgement the write path makes that the read path does not: a CIP-105 id carries NO
      -- header byte, so it cannot say which kind of credential it names, and @drep@ is the HRP for
      -- both. Defaulting to the key arm would silently mis-claim every script DRep, so it is refused.
      testCase "a CIP-105 drep id is refused, because it cannot say key or script" $
        parseClaimCredential drepCip105 @?= Left CredentialMalformed,
      -- A committee cold credential is claimable: the rule is the same for all three identifier
      -- families, because all three are a Credential.
      testCase "a CIP-129 committee cold id is claimable too" $
        (isScriptCredential . claimedCredentialOf <$> parseClaimCredential ccColdBech32) @?= Right False,
      -- Review Focus item 3, off-chain half. Its own code and its own status, because an issuer
      -- naming a subject that does not exist is a different mistake from an issuer with no profile:
      -- the record that would result can never be counter-signed and can never be removed.
      testCase "a missing subject is its own 404, not the issuer's ProfileNotFound" $
        ( txBuildingExceptionCode SubjectProfileNotFound,
          txBuildingExceptionToHttpStatus SubjectProfileNotFound,
          txBuildingExceptionToHttpStatus ProfileNotFound
        )
          @?= ("SubjectProfileNotFound", 404, 404),
      -- Review Focus item 4, off-chain half — stated as a courtesy, not a guarantee, and the message
      -- has to say so, because nothing on chain refuses the second dispute.
      testCase "a second dispute while one is open is refused, and the message calls it a courtesy" $
        assertBool
          "the message does not claim a protocol rule"
          ("not a protocol rule" `isInfixOf` displayException DisputeAlreadyOpen),
      -- The HTTP code existed and was unreachable before this task gave it an exception to come from.
      testCase "a dispute that does not exist is a 404, which the wire code already promised" $
        (txBuildingExceptionCode DisputeNotFound, txBuildingExceptionToHttpStatus DisputeNotFound)
          @?= ("DisputeNotFound", 404),
      testCase "the witness is a parameter, so a script-held user NFT can be spent" $ do
        -- The other half of this case is 'spendWithGivenWitness' above, which pins the parameter at
        -- the type level; bound here so the binding is used and cannot rot unnoticed.
        let _pinnedByItsType = spendWithGivenWitness
        let witnesses = [WitnessKey, WitnessSimpleScript nativeScriptA]
        map (isKeyWitness . claimWitnessToTxInWitness) witnesses @?= [True, False],
      -- Fix #4's off-chain half: the date is no longer client input at all. The derived Swagger of
      -- the action type IS the request body of /build-tx and the source of the generated document,
      -- and it listed `aa_attestation_date` until this task — measured, in
      -- docs/generated/swagger/interaction-swagger-api.json.
      testCase "the issue-attestation request carries no date field" $
        assertBool
          "no date in the request type"
          (not ("attestation_date" `isInfixOf` schemaJson @ProfileActionType)),
      ---- the whole published error table -------------------------------------------------------
      --
      -- Every constructor, by value, with no catch-all on either side. The failure label is the
      -- code, so a wrong row names itself instead of printing two 26-element lists.
      testCase "every TxBuildingException serves the status and the code the table publishes" $
        mapM_
          ( \(e, status, code) ->
              assertEqual code (status, code) (txBuildingExceptionToHttpStatus e, txBuildingExceptionCode e)
          )
          publishedErrorTable,
      -- The DOMAIN of the table, structurally. 'constructorsOf' reads the number off the type's
      -- 'Generic' representation, so a twenty-seventh constructor fails HERE, with the row count it
      -- expected and the one it found — rather than inheriting a status nobody chose and being
      -- discovered by a client. This is the assertion the @_ = 400@ made impossible to write.
      testCase "the table covers every constructor of TxBuildingException, each exactly once" $ do
        assertEqual
          "a constructor was added to TxBuildingException and not to publishedErrorTable"
          (constructorsOf @TxBuildingException)
          (length publishedErrorTable)
        assertEqual
          "two rows publish the same code"
          (length publishedErrorTable)
          (length (nub [code | (_, _, code) <- publishedErrorTable]))
    ]
