{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Behavioural guards for three conjuncts that no test noticed the absence of.
--
-- __Why this module exists.__ A mutation run deleted @traceIfFalse \"M0\"@ — the protocol-pause gate
-- on every mint — and the whole @A1@ conjunct — the attestation-acceptance rule — from the on-chain
-- code. 526 tests ran and one failed: @UnitTests.ScriptSize@, because the scripts got /smaller/. Not
-- one behavioural test observed that the pause gate and the acceptance rule had vanished. A suite
-- that detects a deletion only by the byte count is not testing the rule.
--
-- The emulator cases could not have caught it. @UnitTests.Pause@'s 7.1 and 7.2 cover @P6@ and @D7@
-- and say so; @pauseStopsEverything@ in @UnitTests.Attestation@ covers the mint path with a bare
-- 'mustFail', which the off-chain builder's @ProtocolPaused@ satisfies before any script runs — so
-- @M0@ could be deleted and that case would go on passing. Acceptance has the same shape: the happy
-- path asserts that an accept SUCCEEDS, and deleting the rule that constrains it does not make a
-- success fail.
--
-- __The discipline here, and it is the whole point.__ A negative case that asserts @False@ is worth
-- nothing on its own: it stays green when the context is refused for some unrelated reason, which is
-- exactly the failure mode that produced this module. So every case asserts a __pair__ — the
-- otherwise-identical valid context must give 'True' and the broken one 'False' — on contexts that
-- differ in one field. Delete the conjunct and the pair becomes @(True, True)@; break the fixture and
-- it becomes @(False, _)@. Either way the case is red. This is 7.1's \"unpaused must succeed first\"
-- rule, moved into a pure test.
--
-- __Why pure and not the emulator.__ These three lambdas are @ScriptContext -> Bool@ functions of
-- their argument, exported for exactly this, so the rule is pinned without a ledger: the test names
-- the conjunct it breaks, and no transaction builder, balancer or off-chain guard sits between the
-- assertion and the check. The emulator groups remain the authority on whether an honest client can
-- build the transaction at all.
--
-- __What is NOT here.__ One case per conjunct and no more: @A3@, @P6@, @Mp2@-@Mp6@, @Md*@ and the
-- Disputes Validator are out of scope. Nothing here replaces @UnitTests.ScriptSize@ either — a
-- deletion that this module catches should also move the recorded script size, and the two
-- assertions disagreeing is information.
module UnitTests.MutationGuards (tests) where

import Data.ByteString qualified as BS
import Data.Word (Word8)
import Palmares.Onchain.CIP68
  ( CIP68Datum (..),
    MetadataFields (..),
    deriveUserFromRefAC,
    generateRefAndUserTN,
    mkCIP68Datum,
    updateCIP68DatumMetadata,
  )
import Palmares.Onchain.Protocol.Types
  ( AttestationKind (MilestoneDelivered),
    OnchainAttestation (..),
    OnchainProfile (..),
    OnchainProfileKind (Community),
    OracleParams (..),
    ProtocolParams (..),
  )
import Palmares.Onchain.Utils (nameFromTxOutRef)
import Palmares.Onchain.Validators.AttestationsValidator
  ( AttestationsRedeemer (AcceptAttestation),
    attestationsLambda,
  )
import Palmares.Onchain.Validators.MintingPolicy
  ( MintingRedeemer (MintProfile),
    mintingPolicyLambda,
  )
import Palmares.Onchain.Validators.ProfilesValidator
  ( ProfilesRedeemer (UpdateProfile),
    profilesLambda,
  )
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (PubKeyCredential),
    Datum (..),
    OutputDatum (NoOutputDatum, OutputDatum),
    POSIXTime (..),
    PubKeyHash (..),
    Redeemer (..),
    ScriptContext (..),
    ScriptHash (..),
    ScriptInfo (MintingScript, SpendingScript),
    TxId (..),
    TxInInfo (..),
    TxInfo (..),
    TxOut (..),
    TxOutRef (..),
    Value,
    always,
  )
import PlutusLedgerApi.V3.MintValue (MintValue (UnsafeMintValue), emptyMintValue)
import PlutusTx (toBuiltinData)
import PlutusTx.AssocMap qualified as AssocMap
import PlutusTx.Builtins (BuiltinByteString, BuiltinData, toBuiltin)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "mutation guards"
    [ m0Tests,
      a1Tests,
      p3Tests
    ]

-------------------------------------------------------------------------------

-- * M0 — the protocol-pause gate on every mint

-------------------------------------------------------------------------------

-- | @M0@: @traceIfFalse \"M0\" (not (opPaused oracle))@, the global gate in 'mintingPolicyLambda'.
--
-- The mint it is gating has to be a mint the policy otherwise accepts, or the case proves nothing:
-- 'mintProfileCtx' satisfies @Mp1@ through @Mp6@ and @K2@, and its only parameter is the pause flag
-- in the oracle datum the policy reads through @oracleToken@. So the two halves of the pair differ in
-- exactly one boolean, and the conjunct under test is the only thing that can read it — nothing else
-- on the @MintProfile@ path touches 'opPaused'.
m0Tests :: TestTree
m0Tests =
  testGroup
    "M0: a paused protocol mints nothing"
    [ testCase "Test Case 8.1: the pause flag is the only thing between this profile mint and acceptance (M0)" $
        ( mintingPolicyLambda params (mintProfileCtx False),
          mintingPolicyLambda params (mintProfileCtx True)
        )
          @?= (True, False)
    ]

-- | A profile mint the policy accepts, parameterised __only__ by @opPaused@.
--
-- Index 0 is the state output (@Mp5@) and carries no user token (@Mp6@); index 1 is the change output
-- that holds the user NFT, which is where authority belongs and which nothing on chain constrains.
mintProfileCtx :: Bool -> ScriptContext
mintProfileCtx paused =
  ScriptContext
    (mkTxInfo [seedInput] [oracleRefInput paused] [stateOut, changeOut] profileMint)
    (Redeemer (toBuiltinData redeemer))
    (MintingScript protocolCS)
  where
    redeemer = MintProfile profileSeedRef Community Nothing profileFields 0
    -- Mp1: the seed must actually be spent, which is what makes the derived id unique.
    seedInput = TxInInfo profileSeedRef (plainOut walletAddr (lv 10_000_000))
    stateOut = inlineOut profilesAddr profileStateValue (toBuiltinData profileDatum)
    changeOut = plainOut walletAddr (V1.assetClassValue profileUserAC 1 <> lv 5_000_000)

-- | @Mp2@: the transaction mints the profile's ref and user NFT and nothing else, and burns nothing.
profileMint :: MintValue
profileMint =
  UnsafeMintValue
    ( AssocMap.singleton
        protocolCS
        (AssocMap.unsafeFromList [(profileRefTN, 1), (profileUserTN, 1)])
    )

-------------------------------------------------------------------------------

-- * A1 — the attestation-acceptance rule

-------------------------------------------------------------------------------

-- | @A1@: the conjunct in 'attestationsLambda' that makes an acceptance mean something, and it is
-- three statements rather than one — the record is re-locked with @isAccepted = True@, the subject's
-- user NFT is spent, and the UTxO being spent is the attestation it claims to be.
--
-- One case per statement, each breaking that statement alone, because the mutation that produced this
-- module deleted the conjunct whole: a single case would catch the whole deletion but would not tell
-- you which of the three went. Every context here keeps @A3@ satisfied — the input datum is pending,
-- never already accepted — so @A3@ cannot be what refuses them.
a1Tests :: TestTree
a1Tests =
  testGroup
    "A1: what an acceptance must actually do"
    [ testCase "Test Case 8.2: the acceptance must be WRITTEN, not merely transacted (A1)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          -- The same transaction re-locking the datum it came in with: the attestation is spent,
          -- the subject consents, and `isAccepted` stays False. Nothing happened, and the chain
          -- must say so rather than let a no-op count as an acceptance.
          attestationsLambda
            ( acceptCtx
                attestationOwnValue
                [subjectConsentInput]
                (inlineOut attestationsAddr attestationOwnValue (toBuiltinData pendingAttestationDatum))
            )
        )
          @?= (True, False),
      testCase "Test Case 8.3: the SUBJECT must consent, by spending the user NFT derived from its id (A1)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          -- The counter-signature is the whole protocol: without this half anyone could accept an
          -- attestation about anybody, and the record would read as consented to.
          attestationsLambda (acceptCtx attestationOwnValue [noConsentInput] acceptedStateOut)
        )
          @?= (True, False),
      testCase "Test Case 8.4: the UTxO being spent must hold the attestation NFT its datum names (A1)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          -- A datum that merely parses is not state — the same distinction `isUnbackedDatum` draws
          -- for the sweep. Without this half, a parked copy of a real attestation's datum could be
          -- "accepted", and the acceptance would be indistinguishable from the real one to anything
          -- that reads datums rather than values. The output is re-locked at the lovelace-only value
          -- so that the re-lock half of A1 still passes and this case isolates the backing check.
          attestationsLambda
            (acceptCtx (lv minLovelace) [subjectConsentInput] (acceptedStateOutOf (lv minLovelace)))
        )
          @?= (True, False)
    ]

-- | An acceptance with its three moving parts supplied: the value the attestation UTxO holds, the
-- inputs beside it, and the output that re-locks it. Everything else is fixed and valid.
--
-- No reference inputs: 'attestationsLambda' reads no oracle, which is the documented reason the pause
-- does not cover acceptance (see @UnitTests.Pause@'s header).
acceptCtx :: Value -> [TxInInfo] -> TxOut -> ScriptContext
acceptCtx ownValue extraInputs stateOut =
  ScriptContext
    (mkTxInfo (ownInput : extraInputs) [] [stateOut] emptyMintValue)
    (Redeemer (toBuiltinData (AcceptAttestation 0)))
    (SpendingScript attestationOwnRef (Just (Datum (toBuiltinData pendingAttestationDatum))))
  where
    ownInput =
      TxInInfo attestationOwnRef (inlineOut attestationsAddr ownValue (toBuiltinData pendingAttestationDatum))

-- | The subject spending the user NFT derived from its profile id — the consent @A1@ asks for.
subjectConsentInput :: TxInInfo
subjectConsentInput =
  TxInInfo
    (TxOutRef (TxId (b32 0xb2)) 0)
    (plainOut walletAddr (V1.assetClassValue profileUserAC 1 <> lv 5_000_000))

-- | The same input proving nothing: ordinary lovelace in place of the subject's user NFT.
noConsentInput :: TxInInfo
noConsentInput = TxInInfo (TxOutRef (TxId (b32 0xb2)) 0) (plainOut walletAddr (lv 5_000_000))

-- | The re-lock output @A1@ requires: same address, at least the same value, @isAccepted = True@.
acceptedStateOut :: TxOut
acceptedStateOut = acceptedStateOutOf attestationOwnValue

acceptedStateOutOf :: Value -> TxOut
acceptedStateOutOf value = inlineOut attestationsAddr value (toBuiltinData acceptedAttestationDatum)

-------------------------------------------------------------------------------

-- * P3 — the profile's user NFT on every update

-------------------------------------------------------------------------------

-- | @P3@: @traceIfFalse \"P3\" $ V1.assetClassValueOf (valueSpent txInfo) profileUserAssetClass == 1@
-- in @handleUpdateProfile@ — the only thing that makes a profile's metadata its owner's to change.
--
-- The valid half deliberately carries the user NFT in a __separate wallet input__ rather than in the
-- profile UTxO itself. A user token locked beside the state would satisfy @P3@ from the profile's own
-- input, which is the hole @Mp6@ exists to close; putting it in the owner's own UTxO is the honest
-- shape and keeps this case about @P3@ rather than about @Mp6@.
p3Tests :: TestTree
p3Tests =
  testGroup
    "P3: only the holder of the user NFT may rewrite a profile"
    [ testCase "Test Case 8.5: a profile update must spend the profile's user NFT (P3)" $
        ( profilesLambda (updateCtx [userConsentInput]),
          profilesLambda (updateCtx [noUserConsentInput])
        )
          @?= (True, False)
    ]

-- | A profile update the validator accepts, parameterised only by the inputs beside the profile.
--
-- The oracle is present and unpaused, so @P6@ passes and cannot be what refuses the broken half;
-- @P2@ (the own value holds the Ref NFT), @P4@ (field sizes) and @P5@ (the re-locked output) all hold
-- in both halves, the output datum being computed with the protocol's own
-- 'updateCIP68DatumMetadata' so the test cannot disagree with the validator about what an update does.
updateCtx :: [TxInInfo] -> ScriptContext
updateCtx extraInputs =
  ScriptContext
    (mkTxInfo (ownInput : extraInputs) [oracleRefInput False] [stateOut] emptyMintValue)
    (Redeemer (toBuiltinData (UpdateProfile updatedProfileFields 0)))
    (SpendingScript profileOwnRef (Just (Datum (toBuiltinData profileDatum))))
  where
    ownInput = TxInInfo profileOwnRef (inlineOut profilesAddr profileStateValue (toBuiltinData profileDatum))
    stateOut =
      inlineOut
        profilesAddr
        profileStateValue
        (toBuiltinData (updateCIP68DatumMetadata updatedProfileFields profileDatum))

-- | The owner spending the profile's user NFT from their own wallet UTxO.
userConsentInput :: TxInInfo
userConsentInput =
  TxInInfo
    (TxOutRef (TxId (b32 0xa2)) 0)
    (plainOut walletAddr (V1.assetClassValue profileUserAC 1 <> lv 5_000_000))

-- | A stranger paying the fees and holding no authority over this profile.
noUserConsentInput :: TxInInfo
noUserConsentInput = TxInInfo (TxOutRef (TxId (b32 0xa2)) 0) (plainOut walletAddr (lv 5_000_000))

updatedProfileFields :: MetadataFields
updatedProfileFields =
  Metadata222
    { metadataName = "Intersect Community",
      metadataDescription = "A description a stranger must not be able to write",
      metadataImageURI = "ipfs://QmCommunityUpdated"
    }

-------------------------------------------------------------------------------

-- * Protocol fixtures

-------------------------------------------------------------------------------

-- | The minting policy's compile-time parameter. Passed to 'mintingPolicyLambda' directly and
-- embedded in the profile datum, which is the route 'profilesLambda' takes to the oracle token.
params :: ProtocolParams
params =
  ProtocolParams
    { profilesValidatorScriptHash = profilesSH,
      attestationsValidatorScriptHash = attestationsSH,
      disputesValidatorScriptHash = disputesSH,
      oracleToken = oracleAC
    }

-- | The oracle UTxO as a reference input — the only route any validator here has to 'opPaused'.
--
-- 'Palmares.Onchain.Protocol.Lookup.readOracleParams' finds it by its NFT and traces @K1@ if no
-- reference input carries one, so this must be present in every context that reads the oracle.
oracleRefInput :: Bool -> TxInInfo
oracleRefInput paused =
  TxInInfo
    (TxOutRef (TxId (b32 0x0f)) 0)
    (inlineOut oracleAddr (V1.assetClassValue oracleAC 1 <> lv 3_500_000) (toBuiltinData (oracleParamsWith paused)))

-- | No fee configured, so @K2@ passes and the fee path cannot be what refuses a mint here.
oracleParamsWith :: Bool -> OracleParams
oracleParamsWith paused =
  OracleParams
    { opAdminPkh = PubKeyHash (b28 0x01),
      opPaused = paused,
      opFeeConfig = Nothing,
      opMinUTxOValue = minLovelace,
      opDisputeDeposit = 5_000_000
    }

-- | The ids, derived with the protocol's own generator from the same seed the redeemer names, so the
-- fixture cannot disagree with @handleMintProfile@ about what a profile's token names are.
profileSeedRef :: TxOutRef
profileSeedRef = TxOutRef (TxId (b32 0xa0)) 0

profileRefTN :: V1.TokenName
profileUserTN :: V1.TokenName
(profileRefTN, profileUserTN) = generateRefAndUserTN (nameFromTxOutRef profileSeedRef)

profileRefAC :: V1.AssetClass
profileRefAC = V1.AssetClass (protocolCS, profileRefTN)

-- | Derived rather than assembled from 'profileUserTN', which is what @P3@ and @A1@ actually ask for.
profileUserAC :: V1.AssetClass
profileUserAC = deriveUserFromRefAC profileRefAC

profileFields :: MetadataFields
profileFields =
  Metadata222
    { metadataName = "Intersect Community",
      metadataDescription = "A community that corresponds to no on-chain credential",
      metadataImageURI = "ipfs://QmCommunity"
    }

-- | A Community claiming no credential, so @Mp3@ has nothing to prove and cannot refuse the mint.
profileDatum :: CIP68Datum OnchainProfile
profileDatum = mkCIP68Datum profileInfo profileFields []
  where
    profileInfo =
      OnchainProfile
        { profileId = profileRefAC,
          profileKind = Community,
          profileCredential = Nothing,
          protocolParams = params
        }

-- | What @Mp5@ requires the mint to lock, and what the profile UTxO therefore holds afterwards.
profileStateValue :: Value
profileStateValue = V1.assetClassValue profileRefAC 1 <> lv minLovelace

profileOwnRef :: TxOutRef
profileOwnRef = TxOutRef (TxId (b32 0xa1)) 0

attestationOwnRef :: TxOutRef
attestationOwnRef = TxOutRef (TxId (b32 0xb1)) 0

attestationAC :: V1.AssetClass
attestationAC = V1.AssetClass (protocolCS, fst (generateRefAndUserTN (nameFromTxOutRef seed)))
  where
    seed = TxOutRef (TxId (b32 0xb0)) 0

-- | A second profile's ref token, standing in for the issuer. Nothing in 'attestationsLambda' reads
-- it; it is here so the datum is a datum a mint could have produced.
issuerRefAC :: V1.AssetClass
issuerRefAC = V1.AssetClass (protocolCS, fst (generateRefAndUserTN (nameFromTxOutRef seed)))
  where
    seed = TxOutRef (TxId (b32 0xc0)) 0

-- | The attestation as @handleNewAttestation@ wrote it: @isAccepted = False@, which keeps @A3@
-- satisfied so that @A1@ is the only conjunct left to refuse an acceptance.
attestation :: OnchainAttestation
attestation =
  OnchainAttestation
    { attestationId = attestationAC,
      attestationIssuer = issuerRefAC,
      attestationSubject = profileRefAC,
      attestationKind = MilestoneDelivered,
      attestationDate = POSIXTime 1_700_000_000_000,
      attestationPeriod = Nothing,
      attestationIsAccepted = False
    }

pendingAttestationDatum :: CIP68Datum OnchainAttestation
pendingAttestationDatum = mkCIP68Datum attestation attestationFields []
  where
    attestationFields =
      Metadata222
        { metadataName = "Milestone 3 delivered",
          metadataDescription = "The third milestone of Catalyst Fund 12 project 1200123 was delivered",
          metadataImageURI = "ipfs://QmMilestone3"
        }

-- | The datum @A1@ computes for the output, written with the same record update the validator uses.
acceptedAttestationDatum :: CIP68Datum OnchainAttestation
acceptedAttestationDatum = pendingAttestationDatum {extra = attestation {attestationIsAccepted = True}}

attestationOwnValue :: Value
attestationOwnValue = V1.assetClassValue attestationAC 1 <> lv minLovelace

-------------------------------------------------------------------------------

-- * Hashes, addresses, values

-------------------------------------------------------------------------------

-- | This protocol's minting policy symbol, chosen freely: the policy learns its own symbol from the
-- script info rather than from anything these fixtures compute.
protocolCS :: V1.CurrencySymbol
protocolCS = V1.CurrencySymbol (b28 0x07)

-- | The oracle NFT, with the empty token name the one-shot policy mints (see @TestRuns@).
oracleAC :: V1.AssetClass
oracleAC = V1.AssetClass (V1.CurrencySymbol (b28 0x06), V1.TokenName "")

profilesSH :: ScriptHash
profilesSH = ScriptHash (b28 0x03)

attestationsSH :: ScriptHash
attestationsSH = ScriptHash (b28 0x04)

disputesSH :: ScriptHash
disputesSH = ScriptHash (b28 0x05)

-- | Built with the ledger's own derivation, which is also what the minting policy calls, so the
-- expected address in a @Mp5@/@Mk@ check cannot drift from the one the test builds.
profilesAddr :: Address
profilesAddr = V1.scriptHashAddress profilesSH

attestationsAddr :: Address
attestationsAddr = V1.scriptHashAddress attestationsSH

oracleAddr :: Address
oracleAddr = V1.scriptHashAddress (ScriptHash (b28 0x02))

walletAddr :: Address
walletAddr = Address (PubKeyCredential (PubKeyHash (b28 0x01))) Nothing

-- | @opMinUTxOValue@, which is where every state output's minimum comes from.
minLovelace :: Integer
minLovelace = 2_000_000

lv :: Integer -> Value
lv = V1.lovelaceValue . V1.Lovelace

-------------------------------------------------------------------------------

-- * Context plumbing

-------------------------------------------------------------------------------

-- | Everything these three lambdas never read, filled in once.
--
-- The validity range is 'always' on purpose: none of @M0@, @A1@ or @P3@ is a date check, and the one
-- mint path used here (@MintProfile@) has none either — @Ml@ and @Md6@ belong to the other two.
mkTxInfo :: [TxInInfo] -> [TxInInfo] -> [TxOut] -> MintValue -> TxInfo
mkTxInfo ins refIns outs mint =
  TxInfo
    { txInfoInputs = ins,
      txInfoReferenceInputs = refIns,
      txInfoOutputs = outs,
      txInfoFee = V1.Lovelace 1_000_000,
      txInfoMint = mint,
      txInfoTxCerts = [],
      txInfoWdrl = AssocMap.empty,
      txInfoValidRange = always,
      txInfoSignatories = [],
      txInfoRedeemers = AssocMap.empty,
      txInfoData = AssocMap.empty,
      txInfoId = TxId (b32 0xee),
      txInfoVotes = AssocMap.empty,
      txInfoProposalProcedures = [],
      txInfoCurrentTreasuryAmount = Nothing,
      txInfoTreasuryDonation = Nothing
    }

-- | An output carrying an INLINE datum, which is the only datum shape these validators accept:
-- 'Palmares.Onchain.Utils.isGivenInlineDatum' refuses a hash or an absent datum outright.
inlineOut :: Address -> Value -> BuiltinData -> TxOut
inlineOut addr value datum =
  TxOut
    { txOutAddress = addr,
      txOutValue = value,
      txOutDatum = OutputDatum (Datum datum),
      txOutReferenceScript = Nothing
    }

plainOut :: Address -> Value -> TxOut
plainOut addr value =
  TxOut
    { txOutAddress = addr,
      txOutValue = value,
      txOutDatum = NoOutputDatum,
      txOutReferenceScript = Nothing
    }

-- | A hash-sized and a transaction-id-sized constant byte string.
--
-- Nothing here parses an address or verifies a hash, so the bytes are arbitrary; the sizes are the
-- ledger's so that a fixture that does leak into a serialised datum looks like what it stands for,
-- and distinct fixtures stay distinguishable.
b28 :: Word8 -> BuiltinByteString
b28 w = toBuiltin (BS.replicate 28 w)

b32 :: Word8 -> BuiltinByteString
b32 w = toBuiltin (BS.replicate 32 w)
