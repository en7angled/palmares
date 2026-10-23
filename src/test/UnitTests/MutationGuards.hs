{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Behavioural guards for three conjuncts that no test noticed the absence of.
--
-- __Why this module exists.__ A mutation run deleted @traceIfFalse \"M0\"@ — the protocol-pause gate
-- on every mint — and the whole acceptance conjunct, then named @A1@ and since split into
-- @A1@/@A5@/@A6@ — from the on-chain
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
-- __What is NOT here.__ One case per conjunct and no more: @A3@, @P6@, @Mp2@-@Mp6@ and the rest of
-- @Md*@ are out of scope. Nothing here replaces @UnitTests.ScriptSize@ either — a deletion that this
-- module catches should also move the recorded script size, and the two assertions disagreeing is
-- information.
--
-- __What the later waves added, and the one sentence that changed.__ The header above said the
-- Disputes Validator was out of scope; 'd6Tests' now reaches into it, because @D6@ is the one
-- Disputes conjunct whose statement is about the shape of the INPUT LIST and so the one a hand-built
-- context can make while every other conjunct still passes. The groups below close @Mp1@, @Mh@ and
-- @Md1@ (the seed check on all three mint paths), @K1@ (the oracle read itself), @D6@, and @K2@ with
-- the two facts about @feeFor@ that sit either side of it.
--
-- __And @K2@ was wrongly written off as emulator-only__, which is worth recording because the
-- reasoning that excluded it would exclude half of this module. A 'FeeConfig' is a three-field
-- record and @checkFee@ is a pure function of 'OracleParams', a @MintAction@ and @[TxOut]@, so
-- pricing the protocol costs one fixture and the fee payment is one more output. Nothing about it
-- needs a ledger. See 'k2Tests'.
module UnitTests.MutationGuards (tests) where

import Control.Exception (SomeException, evaluate, try)
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
  ( AttestationKind (CredentialClaim, MilestoneDelivered),
    FeeConfig (..),
    OnchainAttestation (..),
    OnchainDispute (..),
    OnchainProfile (..),
    OnchainProfileKind (Community),
    OracleParams (..),
    ProtocolParams (..),
    Verdict (VerdictUpheld),
    resolveDispute,
  )
import Palmares.Onchain.Utils (nameFromTxOutRef)
import Palmares.Onchain.Validators.AttestationsValidator
  ( AttestationsRedeemer (AcceptAttestation),
    attestationsLambda,
  )
import Palmares.Onchain.Validators.DisputesValidator
  ( DisputesRedeemer (ResolveDispute),
    disputesLambda,
  )
import Palmares.Onchain.Validators.MintingPolicy
  ( MintingRedeemer (MintProfile, NewAttestation, OpenDispute),
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
      p3Tests,
      mcTests,
      seedTests,
      k1Tests,
      k2Tests,
      d6Tests
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
    redeemer = MintProfile profileSeedRef Community profileFields 0
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

-- | @A1@, @A5@ and @A6@: what makes an acceptance mean something. It was ONE conjunct named @A1@
-- when these cases were written, over three statements — the record is re-locked with
-- @isAccepted = True@, the subject's user NFT is spent, and the UTxO being spent is the attestation
-- it claims to be. These three cases are what argued it should be three codes, and it now is.
--
-- One case per statement, each breaking that statement alone, because the mutation that produced this
-- module deleted the conjunct whole: a single case would catch the whole deletion but would not tell
-- you which of the three went — which is also why each now has a code of its own. Every context
-- here keeps @A3@ satisfied — the input datum is pending,
-- never already accepted — so @A3@ cannot be what refuses them.
a1Tests :: TestTree
a1Tests =
  testGroup
    "A1/A5/A6: what an acceptance must actually do"
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
      testCase "Test Case 8.3: the SUBJECT must consent, by spending the user NFT derived from its id (A5)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          -- The counter-signature is the whole protocol: without this half anyone could accept an
          -- attestation about anybody, and the record would read as consented to.
          attestationsLambda (acceptCtx attestationOwnValue [noConsentInput] acceptedStateOut)
        )
          @?= (True, False),
      testCase "Test Case 8.4: the UTxO being spent must hold the attestation NFT its datum names (A6)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          -- A datum that merely parses is not state — the same distinction `isUnbackedDatum` draws
          -- for the sweep. Without this half, a parked copy of a real attestation's datum could be
          -- "accepted", and the acceptance would be indistinguishable from the real one to anything
          -- that reads datums rather than values. The output is re-locked at the lovelace-only value
          -- so that the re-lock half of A1 still passes and this case isolates the backing check.
          attestationsLambda
            (acceptCtx (lv minLovelace) [subjectConsentInput] (acceptedStateOutOf (lv minLovelace)))
        )
          @?= (True, False),
      -- D-C. One bit differs between the two halves — `opPaused` in the oracle datum the validator
      -- reads through `attestationOracleToken` — so this is the narrowest possible statement of what
      -- @A7@ does. The pair is what makes it mean something: acceptance must still WORK unpaused, or
      -- `traceIfFalse "A7" False` would pass the negative half on its own.
      --
      -- The emulator case (@UnitTests.Pause@ 7.4) proves the same rule end to end, including that an
      -- attacker's hand-built transaction cannot route around it. This one proves it in a context
      -- where nothing else can be the cause.
      testCase "Test Case 8.17: a paused protocol refuses an acceptance (A7)" $
        ( attestationsLambda (acceptCtx attestationOwnValue [subjectConsentInput] acceptedStateOut),
          attestationsLambda (acceptCtxPaused attestationOwnValue [subjectConsentInput] acceptedStateOut)
        )
          @?= (True, False)
    ]

-- | An acceptance with its three moving parts supplied: the value the attestation UTxO holds, the
-- inputs beside it, and the output that re-locks it. Everything else is fixed and valid.
--
-- __The oracle IS a reference input now__, and it has to be: since D-C, @A7@ reads @opPaused@
-- through 'Palmares.Onchain.Protocol.Types.attestationOracleToken', and `readOracleParams` traces
-- @K1@ when no reference input carries that token. This used to say "no reference inputs:
-- 'attestationsLambda' reads no oracle", which was the documented reason the pause did not cover
-- acceptance.
acceptCtx :: Value -> [TxInInfo] -> TxOut -> ScriptContext
acceptCtx = acceptCtxWith (oracleRefInput False)

-- | The same acceptance under a PAUSED oracle, which is the one bit @A7@ reads.
acceptCtxPaused :: Value -> [TxInInfo] -> TxOut -> ScriptContext
acceptCtxPaused = acceptCtxWith (oracleRefInput True)

acceptCtxWith :: TxInInfo -> Value -> [TxInInfo] -> TxOut -> ScriptContext
acceptCtxWith oracleIn ownValue extraInputs stateOut =
  ScriptContext
    (mkTxInfo (ownInput : extraInputs) [oracleIn] [stateOut] emptyMintValue)
    (Redeemer (toBuiltinData (AcceptAttestation 0)))
    (SpendingScript attestationOwnRef (Just (Datum (toBuiltinData pendingAttestationDatum))))
  where
    ownInput =
      TxInInfo attestationOwnRef (inlineOut attestationsAddr ownValue (toBuiltinData pendingAttestationDatum))

-- | The subject spending the user NFT derived from its profile id — the consent @A5@ asks for.
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

-------------------------------------------------------------------------------

-- | @Mc1@ to @Mc4@: what keeps a credential binding honest — __ADR 0003__.
--
-- Four rules, one context builder, and each case changes exactly one of the three things the rules
-- read: the kind, whether the issuer is the subject, and the credential the redeemer names. @Mk@
-- compares the whole datum against the output, and this builder derives the datum from the same
-- three parameters, so @Mk@ cannot be what refuses any of them.
mcTests :: TestTree
mcTests =
  testGroup
    "Mc1-Mc4: a credential binding is self-issued, names a credential, and proves it"
    [ -- THE POSITIVE CONTROL. Self-issued, names a credential, and that credential signs — so all
      -- four rules pass and every case below fails on the one thing it changes.
      testCase "Test Case 8.18: a well-formed credential claim validates" $
        mintingPolicyLambda params (credentialMintCtx CredentialClaim profileRefAC (Just boundCredential) [boundPkh])
          @?= True,
      -- @Mc1@. A record about one profile issued by ANOTHER would make the issuer field mean
      -- something on these two kinds, where the authority is stated by `Mc3` instead — and would let
      -- a third party mint bindings naming profiles it has nothing to do with.
      testCase "Test Case 8.19: a credential claim issued by a different profile is refused (Mc1)" $
        mintingPolicyLambda params (credentialMintCtx CredentialClaim issuerRefAC (Just boundCredential) [boundPkh])
          @?= False,
      -- @Mc2@. Without it the record would be a binding to nothing, which the read layer would have
      -- to decide how to render.
      testCase "Test Case 8.20: a credential claim naming no credential is refused (Mc2)" $
        mintingPolicyLambda params (credentialMintCtx CredentialClaim profileRefAC Nothing [boundPkh])
          @?= False,
      -- @Mc3@, the rule that was @Mp3@. The credential does not sign, and nothing else changes.
      testCase "Test Case 8.21: a credential claim the credential did not authorise is refused (Mc3)" $
        mintingPolicyLambda params (credentialMintCtx CredentialClaim profileRefAC (Just boundCredential) [])
          @?= False,
      -- @Mc4@, and it is the rule that keeps the OTHER five kinds clean: a milestone carrying a
      -- credential would be a binding nothing checks, since `Mc1` and `Mc3` only look at the two
      -- credential kinds.
      testCase "Test Case 8.22: an ordinary attestation carrying a credential is refused (Mc4)" $
        mintingPolicyLambda params (credentialMintCtx MilestoneDelivered issuerRefAC (Just boundCredential) [boundPkh])
          @?= False
    ]

-- | The key whose credential the records below bind.
boundPkh :: PubKeyHash
boundPkh = PubKeyHash (b28 0x0d)

boundCredential :: Credential
boundCredential = PubKeyCredential boundPkh

-- | A credential-record mint, parameterised in the three things @Mc1@-@Mc4@ read, plus the
-- signatories @Mc3@ reads.
--
-- The seed input carries the ISSUER's user token, so @Mf@ passes whichever profile is named as
-- issuer — which is what lets the @Mc1@ case isolate @Mc1@ instead of tripping over @Mf@.
credentialMintCtx :: AttestationKind -> V1.AssetClass -> Maybe Credential -> [PubKeyHash] -> ScriptContext
credentialMintCtx kind issuer mCredential signatories =
  ScriptContext
    (mkTxInfo [seedInput] [oracleRefInput False] [recordOut] issueMint)
      { txInfoValidRange = datedRange,
        txInfoSignatories = signatories
      }
    (Redeemer (toBuiltinData redeemer))
    (MintingScript protocolCS)
  where
    redeemer =
      NewAttestation issueSeedRef profileFields [] profileRefAC issuer kind datedAt Nothing mCredential 0
    seedInput =
      TxInInfo issueSeedRef (plainOut walletAddr (V1.assetClassValue (deriveUserFromRefAC issuer) 1 <> lv 10_000_000))
    recordOut =
      inlineOut attestationsAddr (V1.assetClassValue issuedAC 1 <> lv minLovelace) (toBuiltinData recordDatum)
    recordDatum =
      mkCIP68Datum
        OnchainAttestation
          { attestationId = issuedAC,
            attestationIssuer = issuer,
            attestationSubject = profileRefAC,
            attestationKind = kind,
            attestationDate = datedAt,
            attestationPeriod = Nothing,
            attestationIsAccepted = False,
            attestationCredential = mCredential,
            attestationOracleToken = oracleAC
          }
        profileFields
        []

-------------------------------------------------------------------------------

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
      opDisputeDeposit = 5_000_000,
      opDisputeTimeoutMs = 2_592_000_000
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

-- | Derived rather than assembled from 'profileUserTN', which is what @P3@ and @A5@ actually ask for.
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
-- satisfied so that @A1@, @A5@ and @A6@ are the only conjuncts left to refuse an acceptance.
attestation :: OnchainAttestation
attestation =
  OnchainAttestation
    { attestationId = attestationAC,
      attestationIssuer = issuerRefAC,
      attestationSubject = profileRefAC,
      attestationKind = MilestoneDelivered,
      attestationDate = POSIXTime 1_700_000_000_000,
      attestationPeriod = Nothing,
      attestationIsAccepted = False,
      attestationCredential = Nothing,
      attestationOracleToken = oracleAC
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
-- The validity range is 'always' on purpose: no acceptance conjunct and neither @M0@ nor @P3@ is a
-- date check, and the one
-- mint path used here (@MintProfile@) has none either — @Mq@ and @Md6@ belong to the other two.
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

-------------------------------------------------------------------------------

-- * Mp1, Mh, Md1 — the seed every id is derived from must actually be spent

-------------------------------------------------------------------------------

-- | The same conjunct in all three mint handlers:
-- @traceIfFalse _ (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs)@ — @Mp1@ in
-- @handleMintProfile@, @Mh@ in @handleNewAttestation@, @Md1@ in @handleOpenDispute@.
--
-- __What it guards, which is not \"uniqueness\" in the abstract.__ Every id here is
-- @generateRefAndUserTN (nameFromTxOutRef seed)@ — a hash of a 'TxOutRef' the REDEEMER names, which
-- is attacker data. Requiring the transaction to spend that ref borrows the ledger's own
-- no-double-spend rule: a 'TxOutRef' is consumable exactly once in the chain's history, so the name
-- derived from it is mintable exactly once. Delete the conjunct and the seed is a nonce the minter
-- picks freely, so the same name is re-derivable at will — and because nothing in this protocol
-- burns, nothing then bounds how many UTxOs carry one id.
--
-- __And the mint checks do not cover it__, which is the reason these three cases are not redundant
-- with @Mp2@/@Mj@/@Md2@: those compare the minted value against the name derived from the seed, so
-- they are satisfied by construction whatever seed is claimed. They say the mint matches the claim;
-- only the seed check says the claim was available to make.
--
-- __Why re-pointing the input is the one field that moves.__ The derived token names, the expected
-- datum and the expected output value all come from the redeemer's seed, which 'withInputRefs'
-- leaves alone — it rewrites only the input's 'TxOutRef' and keeps the resolved 'TxOut'. On all
-- three paths the seed check is the sole reader of an input's ref; every other conjunct reads values
-- (@Mf@, @Md3@), the mint, the outputs, the validity range or an input's ADDRESS (@Md8@), and all of
-- those survive the rewrite untouched.
seedTests :: TestTree
seedTests =
  testGroup
    "Mp1/Mh/Md1: an id is unique only because its seed was spent"
    [ testCase "Test Case 8.6: a profile mint must spend the seed its redeemer names (Mp1)" $
        ( mintingPolicyLambda params (mintProfileCtx False),
          mintingPolicyLambda params (withInputRefs notTheSeedRef (mintProfileCtx False))
        )
          @?= (True, False),
      testCase "Test Case 8.7: an attestation issue must spend the seed its redeemer names (Mh)" $
        ( mintingPolicyLambda params issueAttestationCtx,
          mintingPolicyLambda params (withInputRefs notTheSeedRef issueAttestationCtx)
        )
          @?= (True, False),
      testCase "Test Case 8.8: a dispute opening must spend the seed its redeemer names (Md1)" $
        ( mintingPolicyLambda params openDisputeCtx,
          mintingPolicyLambda params (withInputRefs notTheSeedRef openDisputeCtx)
        )
          @?= (True, False)
    ]

-- | Re-point every input of a context at one 'TxOutRef', leaving the resolved 'TxOut's alone.
--
-- Each context below has exactly one input, so this is \"spend a different UTxO of the same shape\":
-- the transaction still spends the same lovelace, the same tokens, from the same address, and only
-- the identity of the UTxO consumed changes. That is the smallest edit that can break a seed check
-- and it cannot reach any other conjunct.
withInputRefs :: TxOutRef -> ScriptContext -> ScriptContext
withInputRefs ref ctx =
  ctx {scriptContextTxInfo = info {txInfoInputs = [TxInInfo ref out | TxInInfo _ out <- txInfoInputs info]}}
  where
    info = scriptContextTxInfo ctx

-- | A UTxO that is not the seed of anything. One constant serves all three cases, because what each
-- broken half needs is only that the input's ref differ from the one its redeemer names.
notTheSeedRef :: TxOutRef
notTheSeedRef = TxOutRef (TxId (b32 0xdd)) 0

-- | A narrow finite validity window, and every dated context below must override 'mkTxInfo' with it.
--
-- 'Palmares.Onchain.Utils.checkDateInRange' matches only on two 'V1.Finite' bounds and then bounds
-- the WIDTH, so 'always' — which is what 'mkTxInfo' fills in, correctly, for the three undated
-- lambdas this module started with — fails @Mq@ and @Md6@ outright. Without the override the
-- positive control would be 'False' and neither @Mh@ nor @Md1@ would ever be reached.
datedRange :: V1.POSIXTimeRange
datedRange = V1.interval (POSIXTime 1_699_999_000_000) (POSIXTime 1_700_001_000_000)

-- | The instant the dated contexts claim, inside 'datedRange'. The same instant 'attestation'
-- carries, so the two halves of this module date their records alike.
datedAt :: POSIXTime
datedAt = POSIXTime 1_700_000_000_000

-------------------------------------------------------------------------------

-- | An attestation issue the policy accepts, used only as the subject of Test Case 8.7.
--
-- Its own fixtures rather than the acceptance group's: 'attestationAC' is an attestation already on chain, and both
-- its seed and its metadata live in @where@ bindings that a mint redeemer cannot name — and @Mk@
-- compares the whole datum, so a redeemer that cannot reproduce the metadata cannot satisfy it.
--
-- One input does all three jobs the honest transaction gives it: it IS the seed (@Mh@), it holds the
-- issuer's user NFT (@Mf@), and it pays the fee. The metadata is 'profileFields', the one
-- 'MetadataFields' in this module already shown to satisfy @validateMetadataFields@ — Test Case 8.1
-- passes @Mp4@, which is the same function @Mm@ calls — so @Mm@ cannot be what refuses these
-- contexts; @otherMetadata@ is empty, which is what @Mn@ accepts. @Mg@ holds because both ids are
-- 'V1.AssetClass'es of 'protocolCS' with the CIP-67 reference prefix 'generateRefAndUserTN' puts
-- there.
issueAttestationCtx :: ScriptContext
issueAttestationCtx =
  ScriptContext
    (mkTxInfo [seedInput] [oracleRefInput False] [issuedOut] issueMint) {txInfoValidRange = datedRange}
    (Redeemer (toBuiltinData redeemer))
    (MintingScript protocolCS)
  where
    redeemer =
      NewAttestation issueSeedRef profileFields [] profileRefAC issuerRefAC MilestoneDelivered datedAt Nothing Nothing 0
    seedInput =
      TxInInfo issueSeedRef (plainOut walletAddr (V1.assetClassValue issuerUserAC 1 <> lv 10_000_000))
    issuedOut =
      inlineOut attestationsAddr (V1.assetClassValue issuedAC 1 <> lv minLovelace) (toBuiltinData issuedDatum)

issueSeedRef :: TxOutRef
issueSeedRef = TxOutRef (TxId (b32 0xb3)) 0

issuedRefTN :: V1.TokenName
issuedRefTN = fst (generateRefAndUserTN (nameFromTxOutRef issueSeedRef))

issuedAC :: V1.AssetClass
issuedAC = V1.AssetClass (protocolCS, issuedRefTN)

-- | @Mf@'s token: the user half of the issuer's id, derived the way the handler derives it.
issuerUserAC :: V1.AssetClass
issuerUserAC = deriveUserFromRefAC issuerRefAC

-- | The datum @Mk@ requires at the index the redeemer names, built from the redeemer's own arguments
-- with the protocol's own 'mkCIP68Datum' so the fixture cannot disagree with @handleNewAttestation@.
issuedDatum :: CIP68Datum OnchainAttestation
issuedDatum = mkCIP68Datum issued profileFields []
  where
    issued =
      OnchainAttestation
        { attestationId = issuedAC,
          attestationIssuer = issuerRefAC,
          attestationSubject = profileRefAC,
          attestationKind = MilestoneDelivered,
          attestationDate = datedAt,
          attestationPeriod = Nothing,
          attestationIsAccepted = False,
          attestationCredential = Nothing,
          attestationOracleToken = oracleAC
        }

-- | @Mj@: just the attestation's ref NFT, and no user token — the attestation path mints one token.
issueMint :: MintValue
issueMint = UnsafeMintValue (AssocMap.singleton protocolCS (AssocMap.singleton issuedRefTN 1))

-------------------------------------------------------------------------------

-- | A dispute opening the policy accepts, used as the subject of Test Case 8.8 and as the dispute
-- Test Case 8.10 then resolves — the same object seen at both ends of its life, so the two sections
-- cannot drift apart about what a dispute's datum and value are.
--
-- The one input again carries everything: it IS the seed (@Md1@), it holds the opener's user NFT
-- (@Md3@), and it sits at 'walletAddr', which is the address the redeemer names as @depositTo@ and
-- so what satisfies @Md8@. 'attestationAC' is the target and 'profileRefAC' the opener, both
-- reference-prefixed tokens of 'protocolCS' as @Md4@ requires of each. The date is 'datedAt' in both
-- the redeemer and the expected datum, which is what keeps @Md5@ satisfied while @Md6@ passes.
openDisputeCtx :: ScriptContext
openDisputeCtx =
  ScriptContext
    (mkTxInfo [seedInput] [oracleRefInput False] [openedOut] openMint) {txInfoValidRange = datedRange}
    (Redeemer (toBuiltinData redeemer))
    (MintingScript protocolCS)
  where
    redeemer = OpenDispute openSeedRef attestationAC profileRefAC walletAddr profileFields datedAt 0
    seedInput =
      TxInInfo openSeedRef (plainOut walletAddr (V1.assetClassValue profileUserAC 1 <> lv 10_000_000))
    openedOut = inlineOut disputesAddr (disputeValueOf openedAC) (toBuiltinData openedDatum)

openSeedRef :: TxOutRef
openSeedRef = TxOutRef (TxId (b32 0xd0)) 0

openedRefTN :: V1.TokenName
openedRefTN = fst (generateRefAndUserTN (nameFromTxOutRef openSeedRef))

openedAC :: V1.AssetClass
openedAC = V1.AssetClass (protocolCS, openedRefTN)

-- | The dispute @handleOpenDispute@ writes: no verdict yet, the deposit it actually paid recorded in
-- its own datum, and the oracle token it will be read through recorded beside it.
openedDispute :: OnchainDispute
openedDispute =
  OnchainDispute
    { disputeId = openedAC,
      disputeTarget = attestationAC,
      disputeOpenedBy = profileRefAC,
      disputeOpenedAt = datedAt,
      disputeDeposit = depositLovelace,
      disputeDepositTo = walletAddr,
      disputeOracleToken = oracleAC,
      -- The same arithmetic `handleOpenDispute` does, from the same 30 days this module's
      -- `oracleParamsWith` configures: `Md*` compares this whole datum against the output.
      disputeStaleAfter = datedAt + POSIXTime 2_592_000_000,
      disputeVerdict = Nothing
    }

openedDatum :: CIP68Datum OnchainDispute
openedDatum = mkCIP68Datum openedDispute profileFields []

-- | @Md2@: just the dispute's ref NFT. No user token, because there is nothing a dispute's holder
-- may do — resolution is the oracle admin's.
openMint :: MintValue
openMint = UnsafeMintValue (AssocMap.singleton protocolCS (AssocMap.singleton openedRefTN 1))

-------------------------------------------------------------------------------

-- * K1 — the oracle read every gated path begins with

-------------------------------------------------------------------------------

-- | @K1@: the three @traceError \"K1\"@ arms of
-- 'Palmares.Onchain.Protocol.Lookup.readOracleParams', reached here by the UTxO-not-found one — no
-- reference input carries the oracle token at all. The other two (a datum that is not inline, and one
-- that does not decode) need an oracle-shaped UTxO to be present and malformed, which is a different
-- fixture and the same assertion.
--
-- __Why this case is an exception and not a 'False'.__ @PlutusTx.Prelude.traceError@ is
-- @error (trace str ())@, and @PlutusTx.Builtins.Internal.error@ is GHC's @error@, so in plain GHC a
-- traced failure throws. A case asserting 'False' here would never see a 'False': it would die on
-- the exception and report an error rather than a failure, which is a worse diagnostic for the same
-- bug. So the pair is @(Just True, Nothing)@ on the same shape as every other case in this module.
--
-- __This case cannot assert the CODE, only the failure__, and that is a property of @error@ rather
-- than a weakness of the fixture: @error@ ignores its argument, so @trace \"K1\"@ is never forced and
-- the exception carries the generic @\"PlutusTx.Builtins.Internal.error\"@. It does not need to here.
-- With no reference inputs there is exactly one failure the context can reach: @M1@ needs a
-- non-'MintingScript' purpose, @U0@-@U3@ are not on this path, and the oracle read happens before
-- any conjunct — @minLv@ is a bang pattern over it. So a throw from THIS context is @K1@ and nothing
-- else.
--
-- __What deletion means for an arm that cannot be deleted.__ A @traceError@ arm of a @case@ cannot be
-- removed and leave compiling code; the realistic mutation is replacing it with a benign default — an
-- unpaused, unpriced 'OracleParams' — and that is exactly what this case catches, because the broken
-- half would then become @Just True@ and the mint would validate with no oracle in the transaction.
k1Tests :: TestTree
k1Tests =
  testGroup
    "K1: a transaction that does not show the oracle validates nothing"
    [ testCase "Test Case 8.9: a mint carrying no oracle reference input cannot be validated (K1)" $ do
        valid <- runMint (mintProfileCtx False)
        broken <- runMint noOracleMintCtx
        (valid, broken) @?= (Just True, Nothing)
    ]

-- | Run the minting policy, reporting 'Nothing' for a context it could not evaluate at all.
runMint :: ScriptContext -> IO (Maybe Bool)
runMint ctx = either (const Nothing) Just <$> try @SomeException (evaluate (mintingPolicyLambda params ctx))

-- | Test Case 8.1's accepted mint with the oracle reference input taken away and nothing else moved.
noOracleMintCtx :: ScriptContext
noOracleMintCtx = ctx {scriptContextTxInfo = (scriptContextTxInfo ctx) {txInfoReferenceInputs = []}}
  where
    ctx = mintProfileCtx False

-------------------------------------------------------------------------------

-- * D6 — one dispute resolved per transaction

-------------------------------------------------------------------------------

-- | @D6@: @traceIfFalse \"D6\" (Utils.spentExactlyOnceFromAddress ownAddress txInfoInputs)@ in
-- 'disputesLambda' — the conjunct that makes @D4@'s @any@ sound rather than exploitable.
--
-- __The attack, built here rather than described.__ Two open disputes naming the same payout address
-- is the ordinary case — one person contesting two attestations — and resolving both in ONE
-- transaction runs the validator twice against the SAME output list. One returned deposit then
-- satisfies @D4@ for both instances, and the second deposit leaves the script into the transaction's
-- change. @D1@ requires the oracle admin's signature, so the transaction was built by the admin and
-- the change is theirs: one output, two obligations discharged, one deposit stolen.
--
-- __What these two cases add over what already exists.__ @UnitTests.Satisfaction@ pins
-- 'Palmares.Onchain.Utils.spentExactlyOnceFromAddress' as a pure function of an input list, and
-- @UnitTests.Dispute@'s Test Case 6.10 drives the real attack through the emulator with
-- @mustFailWith (failedWithTrace \"D6\")@ — which does pin the code, since deleting @D6@ would let
-- that transaction succeed. Neither can say what these two say: that in the attack transaction every
-- OTHER conjunct passes, for BOTH instances. 6.10 observes one failure somewhere in a transaction;
-- these name the instance, the index it returned at, and the single deposit output that both
-- instances read.
--
-- __Why both instances and not just one.__ Running only the first proves the batch is refused;
-- running the second is what proves the batch was an attack rather than a malformed transaction,
-- because the second instance's @D2@ is satisfied at its own output index and its @D4@ is satisfied
-- by an output it did not pay for. 'batchedInputs' and 'batchedOutputs' are shared by both contexts,
-- so the two cases are provably the same transaction seen from its two script instances.
--
-- The honest halves are the cost @D6@ charges, and it is real: resolutions cannot be batched at all,
-- not even honestly with both deposits returned. 'Palmares.Onchain.Utils.spentExactlyOnceFromAddress'
-- argues that trade; these cases only pin which side of it the validator is on.
d6Tests :: TestTree
d6Tests =
  testGroup
    "D6: one dispute per transaction, which is what makes D4's `any` sound"
    [ testCase "Test Case 8.10: a second dispute input makes the batched resolution refusable (D6)" $
        (disputesLambda resolveAAlone, disputesLambda batchedA) @?= (True, False),
      testCase "Test Case 8.11: the second dispute's own D4 is discharged by the SAME deposit (D6)" $
        (disputesLambda resolveBAlone, disputesLambda batchedB) @?= (True, False)
    ]

-- | The honest resolution of the dispute Test Case 8.8 opened: one dispute input, one deposit back.
resolveAAlone :: ScriptContext
resolveAAlone =
  resolveCtx
    disputeAOwnRef
    openedDatum
    0
    [disputeInputAt disputeAOwnRef openedDatum]
    [resolvedOutputFor openedDatum, returnedDeposit]

-- | The honest resolution of the second dispute, which is the positive control Test Case 8.11 needs:
-- without it, that case's 'False' could be the fixture rather than @D6@.
resolveBAlone :: ScriptContext
resolveBAlone =
  resolveCtx
    disputeBOwnRef
    disputeBDatum
    0
    [disputeInputAt disputeBOwnRef disputeBDatum]
    [resolvedOutputFor disputeBDatum, returnedDeposit]

-- | Both disputes spent, both returned resolved at their own index — and ONE deposit output between
-- them, which is the whole of the attack.
batchedInputs :: [TxInInfo]
batchedInputs = [disputeInputAt disputeAOwnRef openedDatum, disputeInputAt disputeBOwnRef disputeBDatum]

batchedOutputs :: [TxOut]
batchedOutputs = [resolvedOutputFor openedDatum, resolvedOutputFor disputeBDatum, returnedDeposit]

-- | The attack as the first dispute's instance sees it: its own return is output 0.
batchedA :: ScriptContext
batchedA = resolveCtx disputeAOwnRef openedDatum 0 batchedInputs batchedOutputs

-- | The attack as the second dispute's instance sees it: its own return is output 1, and the deposit
-- output it reads for @D4@ is the one the first instance already read.
batchedB :: ScriptContext
batchedB = resolveCtx disputeBOwnRef disputeBDatum 1 batchedInputs batchedOutputs

-- | A resolution, parameterised by the input being spent, its datum, the output index the redeemer
-- names, and the transaction's inputs and outputs.
--
-- Everything else is fixed and valid: the unpaused oracle as a reference input, found through the
-- token the dispute's own datum records, so @D7@ passes; the admin's signature, so @D1@ passes; and
-- 'VerdictUpheld' throughout, because @D4@ returns the deposit on either verdict and the choice
-- cannot be what refuses anything here. The validity range stays the 'always' that 'mkTxInfo' fills
-- in, on purpose: nothing on the resolve path is a date check, so this section needs no 'datedRange'.
resolveCtx :: TxOutRef -> CIP68Datum OnchainDispute -> Integer -> [TxInInfo] -> [TxOut] -> ScriptContext
resolveCtx ownRef ownDatum outputIdx ins outs =
  ScriptContext
    (mkTxInfo ins [oracleRefInput False] outs emptyMintValue) {txInfoSignatories = [adminPkh]}
    (Redeemer (toBuiltinData (ResolveDispute VerdictUpheld outputIdx)))
    (SpendingScript ownRef (Just (Datum (toBuiltinData ownDatum))))

-- | The second dispute, differing from the first in its ID ALONE — and that is as different as
-- resolution can see. The @ResolveDispute@ arm reads 'disputeId', 'disputeDeposit',
-- 'disputeDepositTo', 'disputeOracleToken' and 'disputeVerdict' and nothing else; 'disputeTarget' is
-- the attestation contested, which lives at another address and which this validator never touches.
-- Sharing 'disputeDepositTo' is not a shortcut, it IS the attack's precondition: the same disputer
-- contesting two attestations is what makes one output satisfy both @D4@s.
disputeB :: OnchainDispute
disputeB = openedDispute {disputeId = disputeBAC}

disputeBAC :: V1.AssetClass
disputeBAC = V1.AssetClass (protocolCS, fst (generateRefAndUserTN (nameFromTxOutRef disputeBSeedRef)))

disputeBSeedRef :: TxOutRef
disputeBSeedRef = TxOutRef (TxId (b32 0xd3)) 0

disputeBDatum :: CIP68Datum OnchainDispute
disputeBDatum = openedDatum {extra = disputeB}

-- | The two dispute UTxOs being spent. Distinct refs, because @D6@ counts inputs at an address and
-- 'Palmares.Onchain.Utils.unsafeFindOwnInputByTxOutRef' has to tell the two instances apart.
disputeAOwnRef :: TxOutRef
disputeAOwnRef = TxOutRef (TxId (b32 0xd2)) 0

disputeBOwnRef :: TxOutRef
disputeBOwnRef = TxOutRef (TxId (b32 0xd4)) 0

-- | A dispute UTxO at the dispute address, holding what @Md5@ locked into it.
disputeInputAt :: TxOutRef -> CIP68Datum OnchainDispute -> TxInInfo
disputeInputAt ref d =
  TxInInfo ref (inlineOut disputesAddr (disputeValueOf (disputeId (extra d))) (toBuiltinData d))

-- | The dispute coming back resolved, which is @D2@'s first element.
resolvedOutputFor :: CIP68Datum OnchainDispute -> TxOut
resolvedOutputFor d =
  inlineOut disputesAddr (resolvedValueOf (disputeId (extra d))) (toBuiltinData (resolvedDatumOf d))

-- | The datum @D2@ computes, written with the protocol's own 'resolveDispute' so a change to it
-- shows up here rather than being papered over.
resolvedDatumOf :: CIP68Datum OnchainDispute -> CIP68Datum OnchainDispute
resolvedDatumOf d = d {extra = resolveDispute VerdictUpheld (extra d)}

-- | The ONE returned deposit. Paid to 'walletAddr', which is both disputes' 'disputeDepositTo' and —
-- since 'adminPkh' is the key 'walletAddr' wraps — also the admin's own address, which is exactly
-- the threat model: the builder of the transaction keeps what the second dispute did not get back.
returnedDeposit :: TxOut
returnedDeposit = plainOut walletAddr (lv depositLovelace)

-- | What a dispute UTxO holds: its NFT, its min-UTxO and its deposit, the deposit being part of the
-- locked value rather than a payment to anyone.
disputeValueOf :: V1.AssetClass -> Value
disputeValueOf ac = V1.assetClassValue ac 1 <> lv (minLovelace + depositLovelace)

-- | What @D2@ requires back at the script: the NFT and the min-UTxO, the deposit having left. Stated
-- as an amount rather than as @disputeValueOf ac - lv depositLovelace@, so the test asserts a number
-- instead of agreeing with the validator's arithmetic by construction.
resolvedValueOf :: V1.AssetClass -> Value
resolvedValueOf ac = V1.assetClassValue ac 1 <> lv minLovelace

-- | Read off 'oracleParamsWith' rather than restated, so a reprice of the fixture cannot leave the
-- dispute datums claiming a deposit the oracle no longer names.
depositLovelace :: Integer
depositLovelace = opDisputeDeposit (oracleParamsWith False)

-- | Likewise the admin @D1@ asks to sign: the key 'oracleParamsWith' names, not a copy of it.
adminPkh :: PubKeyHash
adminPkh = opAdminPkh (oracleParamsWith False)

-- | Built with the ledger's own derivation, which is also what the minting policy and the Disputes
-- Validator call, so the expected address in @Md5@ and in @D2@ cannot drift from the one these
-- fixtures build.
disputesAddr :: Address
disputesAddr = V1.scriptHashAddress disputesSH

-------------------------------------------------------------------------------

-- * K2 — the fee a priced protocol charges, and the two actions that are free

-------------------------------------------------------------------------------

-- | @K2@: @traceIfFalse \"K2\"@ in 'Palmares.Onchain.Protocol.Lookup.checkFee' — at least the
-- configured amount, paid to the address the config names — plus the two statements that bound it:
-- @feeFor MintActionDispute = const 0@, and the @feeFor action feeConfig <= 0@ guard above it.
--
-- __What the suite had, and what it did not.__ @UnitTests.Fees@ pins 'feeFor' as a pure mapping —
-- distinct fields per action, no two sharing one, every action free under an all-zero config — which
-- is inherited fix #1's half of this. It never calls @checkFee@, and nor did anything else:
-- @UnitTests.Oracle@'s @setAndClearFees@ sets a 'FeeConfig', reads the datum back and clears it
-- again without minting in between, @TestRuns@ deploys the oracle with @opFeeConfig = Nothing@ so
-- every emulator mint in the repository runs against a protocol priced at nothing — spec §4.3 rules
-- fees out as a business model — and every pure mint context, here and in @UnitTests.DisputeRules@,
-- sets 'Nothing' ON PURPOSE so the fee path cannot be what refuses a case (see 'oracleParamsWith').
-- So the amount 'feeFor' selects was pinned and the ENFORCEMENT of it was never exercised: @K2@
-- could be deleted and nothing in the suite would move.
--
-- __And an emulator case could not have closed it.__ The off-chain builder adds the fee output, so a
-- happy path priced through @OracleSetFees@ succeeds whether or not the validator looks — the exact
-- shape of the two deletions that produced this module. What @K2@ needs is an output list with the
-- fee output REMOVED, which no builder will produce, and @checkFee@ is a pure function of
-- 'OracleParams', a @MintAction@ and @[TxOut]@, so it takes one directly.
--
-- __These complement @UnitTests.Fees@ rather than repeat it.__ Its zero-fee case uses a config whose
-- every field is zero, so an arm mis-wired to another field still returns zero and that case stays
-- green. Test Case 8.14 prices the profile at 3 ADA while asking the DISPUTE path for nothing, which
-- is the config that tells @const 0@ apart from @fcProfileCreationFee@.
--
-- __The positive control is the whole proof, and @checkFee@'s position is why.__ It sits FIRST:
-- @checkFee oracle MintActionProfile txInfoOutputs && handleMintProfile ...@. So a failing @K2@
-- short-circuits and @Mp1@-@Mp6@ never run, and a broken-half 'False' would be indistinguishable
-- from a context that was malformed all along. 'pricedMintCtx' is therefore Test Case 8.1's ACCEPTED
-- mint with two record updates — the oracle datum re-priced, and outputs APPENDED — so the valid
-- half of every pair is a transaction already known to satisfy the whole chain. Appending is safe
-- because @Mp5@ and @Mp6@ read output index 0 and only index 0; the fee lands at index 2.
--
-- __One mutation these cases catch for free, and it is inherited fix #1's own bug.__
-- 'profileFeeLovelace' is deliberately SMALLER than 'attestationFeeLovelace'. @feeFor@ exists so an
-- action cannot be mistyped into a different 'FeeConfig' field — the Belt System's interval fee
-- charged the membership-history field for years — and if @feeFor MintActionProfile@ were re-wired to
-- @fcAttestationFee@ it would demand 7 ADA of an output paying 3, so the VALID half of 8.12, 8.13 and
-- 8.16 would turn 'False'. Priced the other way round the @geq@ would swallow the swap silently.
k2Tests :: TestTree
k2Tests =
  testGroup
    "K2: a priced protocol gets paid, and a free action stays free"
    [ testCase "Test Case 8.12: a priced profile mint that pays no fee at all is refused (K2)" $
        ( mintingPolicyLambda params (pricedMintCtx pricedOracle [feeOut profileFeeLovelace]),
          mintingPolicyLambda params (pricedMintCtx pricedOracle [])
        )
          @?= (True, False),
      -- The amount, isolated from the existence of the output: the fee output is present, at the
      -- right address, one lovelace short. `geq` means "at least", so short is the only side of the
      -- amount that can fail — 8.16 pins the other.
      testCase "Test Case 8.13: one lovelace short of the configured fee is refused (K2)" $
        ( mintingPolicyLambda params (pricedMintCtx pricedOracle [feeOut profileFeeLovelace]),
          mintingPolicyLambda params (pricedMintCtx pricedOracle [feeOut (profileFeeLovelace - 1)])
        )
          @?= (True, False),
      -- OPENING A DISPUTE CARRIES NO PROTOCOL FEE, and it is a product decision rather than an
      -- omission: the deposit already bounds dispute spam and it comes BACK on either verdict, so a
      -- fee on top would make contesting a false claim cost money you never get back — a tax on
      -- exactly the behaviour this registry wants. Both halves read the SAME priced oracle and
      -- neither carries a fee output, so the only difference is the action, which is precisely what
      -- `feeFor` selects on.
      testCase "Test Case 8.14: opening a dispute under the same priced oracle needs no fee output" $
        ( mintingPolicyLambda params pricedOpenDisputeCtx,
          mintingPolicyLambda params (pricedMintCtx pricedOracle [])
        )
          @?= (True, False),
      -- A ZERO FEE IS NO FEE. Without the guard this context would demand an output to the fee
      -- address carrying at least zero lovelace, which no honest transaction has a reason to build —
      -- so `OracleSetFees (Just cfg)` with any zero field would have bricked that action until the
      -- admin noticed. The left half is a `FeeConfig` that IS set, so the `Nothing` arm does not
      -- apply and the guard is the only thing that can accept it.
      testCase "Test Case 8.15: a fee priced at ZERO demands no output, so a zero price is not a brick" $
        ( mintingPolicyLambda params (pricedMintCtx zeroPricedOracle []),
          mintingPolicyLambda params (pricedMintCtx pricedOracle [])
        )
          @?= (True, False),
      -- `geq` and not `==`, deliberately, and recorded because "must pay the required fee" reads
      -- like an equality: the balancer picks the fee output's exact lovelace and a strict equality
      -- would make an ordinary balanced transaction unsubmittable. The same note
      -- `UnitTests.DisputeRules` makes twice about the deposit, which is the one other place this
      -- protocol moves money.
      testCase "Test Case 8.16: paying MORE than the configured fee is accepted" $
        mintingPolicyLambda params (pricedMintCtx pricedOracle [feeOut (profileFeeLovelace + 1)])
          @?= True
    ]

-- | Test Case 8.1's accepted profile mint, re-priced, with a case's fee output APPENDED.
--
-- Two record updates and no re-built fixture, so the valid half of each pair is literally the
-- transaction 8.1 asserts: the oracle reference input's DATUM is swapped for priced params, and the
-- outputs grow at the end. Index 0 stays the state output and index 1 the change, which is what
-- keeps @Mp5@ and @Mp6@ — the only conjuncts that read an output index — untouched.
pricedMintCtx :: OracleParams -> [TxOut] -> ScriptContext
pricedMintCtx ps extraOuts =
  ctx
    { scriptContextTxInfo =
        info
          { txInfoReferenceInputs = [oracleRefInputFor ps],
            txInfoOutputs = txInfoOutputs info <> extraOuts
          }
    }
  where
    ctx = mintProfileCtx False
    info = scriptContextTxInfo ctx

-- | Test Case 8.8's accepted dispute opening with the oracle re-priced and NOTHING else changed —
-- no fee output added, which is the point of Test Case 8.14.
--
-- Re-pricing cannot disturb @Md5@: 'oracleParamsPricedAt' builds on 'oracleParamsWith', so
-- @opMinUTxOValue@ and @opDisputeDeposit@ are the values 'openedDispute' already records.
pricedOpenDisputeCtx :: ScriptContext
pricedOpenDisputeCtx =
  ctx {scriptContextTxInfo = (scriptContextTxInfo ctx) {txInfoReferenceInputs = [oracleRefInputFor pricedOracle]}}
  where
    ctx = openDisputeCtx

-- | The oracle reference input carrying arbitrary params, which is what 'oracleRefInput' is the
-- two-valued special case of.
--
-- Built by swapping the datum of 'oracleRefInput' rather than by restating the address, the value
-- and the ref, so a change to the oracle fixture cannot leave this one behind: @K1@'s own case would
-- go green against an oracle these contexts no longer carry.
oracleRefInputFor :: OracleParams -> TxInInfo
oracleRefInputFor ps = TxInInfo ref (resolved {txOutDatum = OutputDatum (Datum (toBuiltinData ps))})
  where
    TxInInfo ref resolved = oracleRefInput False

-- | Unpaused, with fees configured and the profile mint priced at the given amount.
oracleParamsPricedAt :: Integer -> OracleParams
oracleParamsPricedAt profileFee =
  (oracleParamsWith False)
    { opFeeConfig =
        Just
          FeeConfig
            { fcFeeAddress = feeAddr,
              fcProfileCreationFee = profileFee,
              fcAttestationFee = attestationFeeLovelace
            }
    }

pricedOracle :: OracleParams
pricedOracle = oracleParamsPricedAt profileFeeLovelace

-- | A 'FeeConfig' that IS set and prices a profile at nothing, which is the only state the @<= 0@
-- guard is about. Not the same thing as @opFeeConfig = Nothing@, which the arm above it handles and
-- which 'oracleParamsWith' already gives every other case in this module.
zeroPricedOracle :: OracleParams
zeroPricedOracle = oracleParamsPricedAt 0

-- | Distinct, and the profile's the SMALLER of the two on purpose — see 'k2Tests'.
profileFeeLovelace, attestationFeeLovelace :: Integer
profileFeeLovelace = 3_000_000
attestationFeeLovelace = 7_000_000

-- | An output paying the fee collector, which is all @K2@ looks for.
feeOut :: Integer -> TxOut
feeOut paid = plainOut feeAddr (lv paid)

-- | The fee collector: a key address distinct from every other address in this module, so that no
-- output an existing fixture builds can satisfy @K2@ by accident. If it collided with 'walletAddr'
-- the change output would pay the fee and Test Cases 8.12 and 8.15 would both be vacuous.
feeAddr :: Address
feeAddr = Address (PubKeyCredential (PubKeyHash (b28 0x08))) Nothing
