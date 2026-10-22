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
module UnitTests.WritePath (writePathTests) where

import Control.Exception (displayException)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isInfixOf)
import Data.Proxy (Proxy (..))
import Data.Swagger (ToSchema, toSchema)
import Data.Text (Text)
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
  )
import Palmares.DomainTypes.Core.Actions (ClaimWitness (..), ProfileActionType)
import Palmares.DomainTypes.Core.Ids (parseCredentialCip129)
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
operatorDrepId :: Text
operatorDrepId = claimCredentialToText (PubKeyCredential (paymentKeyHashToPlutus operatorKeyHash))

scriptHashA :: GYScriptHash
scriptHashA = "cabdd19b58d4299fde05b53c2c0baf978bf9ade734b490fc0cc8b7d0"

nativeScriptA :: GYSimpleScript
nativeScriptA = RequireSignature "e1cbb80db89e292269aeb93ec15eb963dda5176b66949fe1c2a6a38a"

-- | The JSON of a type's generated Swagger schema, as a string to search.
schemaJson :: forall a. (ToSchema a) => String
schemaJson = BL8.unpack (encode (toSchema (Proxy :: Proxy a)))

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
        (isScriptCredential <$> parseClaimCredential drepScriptBech32) @?= Right True,
      testCase "a CIP-129 key drep id parses to a key credential" $
        (isScriptCredential <$> parseClaimCredential drepKeyBech32) @?= Right False,
      -- What @admin operator-address@ prints as ATTEST_SMOKE_DREP_ID, pinned at the only place it
      -- can be: the library composition. A test suite cannot import an executable's modules, so
      -- these three assertions pin `claimCredentialToText . PubKeyCredential .
      -- paymentKeyHashToPlutus` and NOT the line in @admin/Main.hs@ that calls it — a change there
      -- to `drepIdCip105`, say, would still be green here. What they do catch is the identity
      -- breaking underneath that line, which is the half that is shared with the write path.
      testCase "the operator key's DRep id parses back to the credential of that same key" $
        parseClaimCredential operatorDrepId
          @?= Right (PubKeyCredential (paymentKeyHashToPlutus operatorKeyHash)),
      -- Not implied by the round-trip above: that one would still hold if the rendering hashed the
      -- key a second time, as long as the parse undid it. The transaction requires
      -- `mustBeSignedBy <the key hash>`, so the 28 bytes the id carries must be the key hash's OWN
      -- bytes — otherwise the printed id names a credential nothing in the wallet can sign for.
      testCase "the id carries the signing key's own 28 bytes, not a rehash of them" $
        (snd <$> parseCredentialCip129 operatorDrepId) @?= Just (keyHashToRawBytes operatorKeyHash),
      -- The consequence, named: `checkCredentialControl`'s key arm is the one that applies, so a
      -- signature proves control. Were this a script credential the claim would need a UTxO at the
      -- script's own address, which an operator mnemonic cannot produce.
      testCase "the operator's own credential is a key, so a signature is proof enough" $
        (isScriptCredential <$> parseClaimCredential operatorDrepId) @?= Right False,
      -- The judgement the write path makes that the read path does not: a CIP-105 id carries NO
      -- header byte, so it cannot say which kind of credential it names, and @drep@ is the HRP for
      -- both. Defaulting to the key arm would silently mis-claim every script DRep, so it is refused.
      testCase "a CIP-105 drep id is refused, because it cannot say key or script" $
        parseClaimCredential drepCip105 @?= Left CredentialMalformed,
      -- A committee cold credential is claimable: the rule is the same for all three identifier
      -- families, because all three are a Credential.
      testCase "a CIP-129 committee cold id is claimable too" $
        (isScriptCredential <$> parseClaimCredential ccColdBech32) @?= Right False,
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
          (not ("attestation_date" `isInfixOf` schemaJson @ProfileActionType))
    ]
