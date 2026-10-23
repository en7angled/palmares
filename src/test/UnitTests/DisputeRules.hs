{-# LANGUAGE OverloadedStrings #-}

-- | What a dispute, a mint and an oracle update must PAY, driven through the validator lambdas.
--
-- __Why this module exists.__ A mutation run over this protocol's forty on-chain trace codes found
-- twenty-one with no test that would go red if the check were deleted. Seven of them are here: @D2@
-- and @D4@ in the Disputes Validator, @Mj@, @Md2@, @Md3@ and @Md6@ in the minting policy, and @O2@ in
-- the Oracle Validator. Every one of them is a statement about a transaction's OUTPUTS or its MINT,
-- which no pure helper can express — so unlike 'UnitTests.Satisfaction' and 'UnitTests.MintInputs',
-- which pin the predicates a validator calls, this module builds a 'ScriptContext' by hand and calls
-- 'disputesLambda', 'mintingPolicyLambda' and 'oracleLambda' directly.
--
-- __The trap, and how every case here avoids it.__ All three validators are @&&@ / @and [...]@ chains
-- that short-circuit, so a malformed context is refused by an EARLIER conjunct and the case then
-- passes for a reason that has nothing to do with the code it names — which is the failure mode that
-- produced this task. So each arm has ONE well-formed transaction, asserted to validate, and every
-- negative case is a record update of it in exactly one place. While the positive control is green,
-- each negative differs from a passing transaction by one field, and that field is the conjunct
-- under test.
--
-- @Md6@ is the sharpest instance of it: @openedAt@ goes into the dispute's datum, and @Md5@ compares
-- the whole datum against the output. Move the date without moving the expected output datum and
-- @Md5@ rejects the context before @Md6@ is ever reached. 'goodOpenDisputeInfo' therefore takes the
-- date and derives both from it.
--
-- __Two traps the Disputes Validator documents are respected, not re-tested.__ @D4@ proves the
-- deposit came back with @any@ over the outputs, which is sound only because @D6@ permits one
-- resolution per transaction; so every case here spends the dispute address exactly ONCE, and the
-- multiple-satisfaction half stays in 'UnitTests.Satisfaction', where it is a pure function of an
-- input list. And the deposit amount comes from the dispute's own datum rather than from the oracle,
-- so no case here moves @opDisputeDeposit@ expecting it to change what @D2@ or @D4@ demand.
--
-- __Where the date window itself is pinned.__ 'Palmares.Onchain.Utils.checkDateInRange' is tested as
-- a function in @UnitTests.OracleRules@, exclusive bounds included. What this module adds is that
-- @Md6@ calls it at all, and calls the WIDTH-checking version — which a test of the function cannot
-- say.
module UnitTests.DisputeRules (tests) where

import Palmares.Onchain.CIP68
  ( CIP68Datum (..),
    MetadataFields (..),
    deriveUserFromRefAC,
    generateRefAndUserTN,
    mkCIP68Datum,
  )
import Palmares.Onchain.Protocol.Types
  ( AttestationKind (MilestoneDelivered),
    OnchainAttestation (..),
    OnchainDispute (..),
    OracleAdminAction (OraclePause),
    OracleParams (..),
    ProtocolParams (..),
    Verdict (VerdictExpired, VerdictRejected, VerdictUpheld),
    applyOracleAdminAction,
    resolveDispute,
  )
import Palmares.Onchain.Utils (maxDateWindow, nameFromTxOutRef)
import Palmares.Onchain.Validators.DisputesValidator (DisputesRedeemer (ExpireDispute, ResolveDispute), disputesLambda)
import Palmares.Onchain.Validators.MintingPolicy
  ( MintingRedeemer (NewAttestation, OpenDispute),
    mintingPolicyLambda,
  )
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate), oracleLambda)
import PlutusLedgerApi.V1.Address (scriptHashAddress)
import PlutusLedgerApi.V1.Interval (interval)
import PlutusLedgerApi.V1.Value (AssetClass (..))
import PlutusLedgerApi.V1.Value qualified as V1
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (PubKeyCredential),
    Datum (..),
    Lovelace (..),
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
  )
import PlutusLedgerApi.V3.MintValue (MintValue (UnsafeMintValue), emptyMintValue)
import PlutusTx (ToData, toBuiltinData)
import PlutusTx.AssocMap qualified as AssocMap
import PlutusTx.Builtins (BuiltinByteString)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "dispute, mint and oracle output rules"
    [ resolveTests,
      expireTests,
      openDisputeMintTests,
      attestationMintTests,
      oracleReturnTests
    ]

-------------------------------------------------------------------------------

-- * Shared fixtures

-------------------------------------------------------------------------------

-- | This protocol's currency symbol, which is what the policy is handed in @MintingScript@.
protocolCS :: V1.CurrencySymbol
protocolCS = V1.CurrencySymbol "c0ffee"

-- | Somebody else's policy. Used only to mint or burn a token this protocol has no opinion about,
-- which is what makes the \"just this NFT\" half of @Mj@ and @Md2@ separable from the
-- \"nothing burns\" half.
otherCS :: V1.CurrencySymbol
otherCS = V1.CurrencySymbol "decafe"

adminPkh, disputerPkh, strangerPkh :: PubKeyHash
adminPkh = PubKeyHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1"
disputerPkh = PubKeyHash "\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2"
strangerPkh = PubKeyHash "\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7\7"

profilesSH, attestationsSH, disputesSH, oracleSH :: ScriptHash
profilesSH = ScriptHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"
attestationsSH = ScriptHash "\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4"
disputesSH = ScriptHash "\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5\5"
oracleSH = ScriptHash "\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6\6"

-- Built with 'scriptHashAddress' rather than by hand, because @Mk@, @Md5@ and @O2@ compare an output
-- address against what the validator computes with that very function — a hand-written address would
-- make the test agree, or disagree, by coincidence.
attestationsAddr, disputesAddr, oracleAddr :: Address
attestationsAddr = scriptHashAddress attestationsSH
disputesAddr = scriptHashAddress disputesSH
oracleAddr = scriptHashAddress oracleSH

-- | Where a deposit goes back to: an ordinary key address, which is what @Md8@ exists to require.
disputerAddr, strangerAddr :: Address
disputerAddr = Address (PubKeyCredential disputerPkh) Nothing
strangerAddr = Address (PubKeyCredential strangerPkh) Nothing

oracleAC :: AssetClass
oracleAC = AssetClass (V1.CurrencySymbol "0rac1e", V1.TokenName "oracle")

protocolParamsFixture :: ProtocolParams
protocolParamsFixture =
  ProtocolParams
    { profilesValidatorScriptHash = profilesSH,
      attestationsValidatorScriptHash = attestationsSH,
      disputesValidatorScriptHash = disputesSH,
      oracleToken = oracleAC
    }

-- | Unpaused, unpriced, 2 ADA of min-UTxO and a 5 ADA deposit. @opFeeConfig@ is 'Nothing' so that
-- @checkFee@ passes for every action and cannot be what refuses a mint case.
oracleParamsFixture :: OracleParams
oracleParamsFixture =
  OracleParams
    { opAdminPkh = adminPkh,
      opPaused = False,
      opFeeConfig = Nothing,
      opMinUTxOValue = minUTxOLv,
      opDisputeDeposit = depositLv,
      opDisputeTimeoutMs = 2_592_000_000
    }

minUTxOLv, depositLv :: Integer
minUTxOLv = 2_000_000
depositLv = 5_000_000

minLvValue :: V1.Value
minLvValue = V1.lovelaceValue (Lovelace minUTxOLv)

-- | The oracle as a REFERENCE input, which is how both the minting policy and the Disputes Validator
-- read it. Takes the params so a paused oracle is one call away.
oracleRefInput :: OracleParams -> TxInInfo
oracleRefInput params =
  TxInInfo (txOutRefAt 9) (txOut oracleAddr (V1.assetClassValue oracleAC 1 <> minLvValue) (inlineOf params))

txOutRefAt :: Integer -> TxOutRef
txOutRefAt = TxOutRef (TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0")

-- | An output. Nothing in this protocol attaches a reference script to one.
txOut :: Address -> V1.Value -> OutputDatum -> TxOut
txOut addr val dat =
  TxOut {txOutAddress = addr, txOutValue = val, txOutDatum = dat, txOutReferenceScript = Nothing}

-- | A plain lovelace output with no datum: a returned deposit, or somebody's change.
lovelaceOutput :: Integer -> Address -> TxOut
lovelaceOutput lv addr = txOut addr (V1.lovelaceValue (Lovelace lv)) NoOutputDatum

-- | An inline datum, which is the only shape 'Palmares.Onchain.Utils.isGivenInlineDatum' accepts.
inlineOf :: (ToData a) => a -> OutputDatum
inlineOf = OutputDatum . Datum . toBuiltinData

-- | A 'MintValue' from one entry per policy.
--
-- Grouped by policy at the call site rather than flattened, because 'AssocMap.unsafeFromList' would
-- otherwise be handed a duplicate currency symbol and the projection then reads whichever entry comes
-- first. A NEGATIVE quantity is a burn, which is the only way to make 'mintValueBurned' non-empty and
-- so the only way to reach that half of @Mj@ and @Md2@.
mintOf :: [(V1.CurrencySymbol, [(V1.TokenName, Integer)])] -> MintValue
mintOf policies =
  UnsafeMintValue
    (AssocMap.unsafeFromList [(cs, AssocMap.unsafeFromList tokens) | (cs, tokens) <- policies])

-- | Exactly one NFT minted, which is what every honest mint in this protocol looks like.
mintOne :: AssetClass -> MintValue
mintOne (AssetClass (cs, tn)) = mintOf [(cs, [(tn, 1)])]

-- | A protocol profile id: this policy's symbol and a CIP-67 REFERENCE name, which is what @Mg@ and
-- @Md4@ require of one. Derived with the protocol's own generator so the test cannot disagree with
-- the implementation about the four prefix bytes.
profileIdFor :: BuiltinByteString -> AssetClass
profileIdFor seed = AssetClass (protocolCS, fst (generateRefAndUserTN seed))

subjectId, issuerId, targetId, openerId, otherProfileId :: AssetClass
subjectId = profileIdFor "subject"
issuerId = profileIdFor "issuer"
targetId = profileIdFor "target"
openerId = profileIdFor "opener"
otherProfileId = profileIdFor "somebodyelse"

metadataFixture :: MetadataFields
metadataFixture =
  Metadata222
    { metadataName = "Milestone was not delivered",
      metadataDescription = "The disputer's statement about the attestation it contests",
      metadataImageURI = "ipfs://QmDisputeStatement"
    }

-- | A transaction with nothing in it. Every context below is a record update of this one, so V3's
-- sixteen 'TxInfo' fields are written out exactly once. The validity range is the honest shape: a
-- narrow window around 'nowT', well inside 'maxDateWindow'.
emptyTxInfo :: TxInfo
emptyTxInfo =
  TxInfo
    { txInfoInputs = [],
      txInfoReferenceInputs = [],
      txInfoOutputs = [],
      txInfoFee = Lovelace 1_000_000,
      txInfoMint = emptyMintValue,
      txInfoTxCerts = [],
      txInfoWdrl = AssocMap.empty,
      txInfoValidRange = interval (t 900) (t 1100),
      txInfoSignatories = [],
      txInfoRedeemers = AssocMap.empty,
      txInfoData = AssocMap.empty,
      txInfoId = TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1",
      txInfoVotes = AssocMap.empty,
      txInfoProposalProcedures = [],
      txInfoCurrentTreasuryAmount = Nothing,
      txInfoTreasuryDonation = Nothing
    }

t :: Integer -> POSIXTime
t = POSIXTime

-- | A date inside 'emptyTxInfo''s validity range.
nowT :: POSIXTime
nowT = t 1000

-------------------------------------------------------------------------------

-- * @D2@ and @D4@: what resolving a dispute has to pay back

-------------------------------------------------------------------------------

openDisputeAC :: AssetClass
openDisputeAC = profileIdFor "disputeseed"

-- | An OPEN dispute: no verdict yet, so @D3@ passes, and 5 ADA of deposit recorded in its own datum.
-- 'disputeDeposit' is what both @D2@ and @D4@ read, and deliberately not 'opDisputeDeposit'.
openDispute :: OnchainDispute
openDispute =
  OnchainDispute
    { disputeId = openDisputeAC,
      disputeTarget = targetId,
      disputeOpenedBy = openerId,
      disputeOpenedAt = nowT,
      disputeDeposit = depositLv,
      disputeDepositTo = disputerAddr,
      disputeOracleToken = oracleAC,
      -- 30 days out, so the resolve cases below are nowhere near the expiry window and @D9@ cannot
      -- be what refuses them. The expiry cases use their own fixture with a deadline in the past.
      disputeStaleAfter = nowT + POSIXTime 2_592_000_000,
      disputeVerdict = Nothing
    }

openDisputeDatum :: CIP68Datum OnchainDispute
openDisputeDatum = mkCIP68Datum openDispute metadataFixture []

-- | What the validator computes the output datum must be: the same record update it makes, so a
-- change to 'resolveDispute' shows up here rather than being papered over.
resolvedDatum :: Verdict -> CIP68Datum OnchainDispute
resolvedDatum verdict = openDisputeDatum {extra = resolveDispute verdict openDispute}

disputeInputRef :: TxOutRef
disputeInputRef = txOutRefAt 1

-- | The dispute UTxO: its NFT, its min-UTxO and its deposit, which is the whole economic mechanism.
disputeInputValue :: V1.Value
disputeInputValue = V1.assetClassValue openDisputeAC 1 <> V1.lovelaceValue (Lovelace (minUTxOLv + depositLv))

-- | What @D2@ requires back at the script: the own value LESS the deposit. Stated as an amount rather
-- than recomputed as @ownValue - depositValue@, so the test asserts a number instead of agreeing with
-- the validator's arithmetic by construction.
resolvedOutputValue :: V1.Value
resolvedOutputValue = V1.assetClassValue openDisputeAC 1 <> minLvValue

-- | The dispute being spent. Its VALUE is a parameter because @D2@'s second element is a claim about
-- exactly that: the UTxO must hold the NFT its own datum names.
disputeInputWith :: V1.Value -> TxInInfo
disputeInputWith val = TxInInfo disputeInputRef (txOut disputesAddr val (inlineOf openDisputeDatum))

-- | The dispute coming back at the script with a verdict written on it, at whatever value.
resolvedOutputOf :: Verdict -> V1.Value -> Address -> TxOut
resolvedOutputOf verdict val addr = txOut addr val (inlineOf (resolvedDatum verdict))

-- | The two outputs a resolution has, as a record rather than a helper's five positional arguments,
-- so a case NAMES the one thing it moves. Every field is part of @D2@ or @D4@: the verdict written
-- and the value and address the dispute comes back at are @D2@'s first element; the amount paid and
-- the address it is paid to are @D4@.
data Settlement = Settlement
  { settledVerdict :: Verdict,
    disputeBackAs :: V1.Value,
    disputeBackTo :: Address,
    depositPaid :: Integer,
    depositPaidTo :: Address
  }

-- | The settlement every case below perturbs in exactly one field.
goodSettlement :: Settlement
goodSettlement =
  Settlement
    { settledVerdict = VerdictUpheld,
      disputeBackAs = resolvedOutputValue,
      disputeBackTo = disputesAddr,
      depositPaid = depositLv,
      depositPaidTo = disputerAddr
    }

-- | A well-formed resolution. Output 0 is the dispute coming back resolved (@D2@); output 1 returns
-- the deposit to the address the disputer named (@D4@). Exactly one input sits at the dispute
-- address, which is what keeps @D6@ satisfied and so what keeps @D4@'s @any@ sound.
goodResolveInfo :: TxInfo
goodResolveInfo = settling goodSettlement

settlementOutputs :: Settlement -> [TxOut]
settlementOutputs s =
  [ resolvedOutputOf (settledVerdict s) (disputeBackAs s) (disputeBackTo s),
    lovelaceOutput (depositPaid s) (depositPaidTo s)
  ]

-- | The resolution transaction this settlement describes. Everything but the outputs is fixed: one
-- input at the dispute address (@D6@), the unpaused oracle as a reference input (@D7@), and the
-- admin's signature (@D1@).
settling :: Settlement -> TxInfo
settling s =
  emptyTxInfo
    { txInfoInputs = [disputeInputWith disputeInputValue],
      txInfoReferenceInputs = [oracleRefInput oracleParamsFixture],
      txInfoOutputs = settlementOutputs s,
      txInfoSignatories = [adminPkh]
    }

-- | Run the @ResolveDispute@ arm, naming an output index for the returned dispute.
runResolve :: Verdict -> Integer -> TxInfo -> Bool
runResolve verdict idx info =
  disputesLambda
    ( ScriptContext
        info
        (Redeemer (toBuiltinData (ResolveDispute verdict idx)))
        (SpendingScript disputeInputRef (Just (Datum (toBuiltinData openDisputeDatum))))
    )

resolveTests :: TestTree
resolveTests =
  testGroup
    "resolving a dispute returns the dispute and the deposit"
    [ -- THE POSITIVE CONTROL, and it is load-bearing for every case below: each of them is this
      -- transaction with one NAMED field changed, so while this is green a negative case cannot be
      -- failing on an earlier conjunct instead of the one it names.
      testCase "a well-formed resolution validates" $
        runResolve VerdictUpheld 0 goodResolveInfo @?= True,
      testCase "either verdict validates, because the deposit comes back on both" $
        runResolve VerdictRejected 0 (settling goodSettlement {settledVerdict = VerdictRejected})
          @?= True,
      -- ---------------------------------------------------------------------------------------
      -- D2, FIRST ELEMENT: the output datum must be the RESOLVED one the validator computed.
      --
      -- Returning the dispute untouched is the whole attack this stops: the deposit leaves the script
      -- and the dispute stays open, so it can be "resolved" again, and again. The one case here that
      -- the 'Settlement' record cannot express, because every output it builds is resolved.
      testCase "returning the dispute with its datum untouched is refused (D2)" $
        runResolve
          VerdictUpheld
          0
          goodResolveInfo
            { txInfoOutputs =
                [ txOut disputesAddr resolvedOutputValue (inlineOf openDisputeDatum),
                  lovelaceOutput depositLv disputerAddr
                ]
            }
          @?= False,
      -- And the verdict written must be the one the REDEEMER names, not merely some verdict:
      -- `resolveDispute` is applied to the redeemer's value and D2 compares the whole datum.
      testCase "writing the other verdict than the redeemer names is refused (D2)" $
        runResolve VerdictUpheld 0 (settling goodSettlement {settledVerdict = VerdictRejected})
          @?= False,
      -- One lovelace short of `ownValue - depositValue`. `geq` means "at least", so the short side is
      -- the only side of the amount that can fail — see two cases down for the other.
      testCase "returning one lovelace less than the value less the deposit is refused (D2)" $
        runResolve
          VerdictUpheld
          0
          ( settling
              goodSettlement
                { disputeBackAs =
                    V1.assetClassValue openDisputeAC 1 <> V1.lovelaceValue (Lovelace (minUTxOLv - 1))
                }
          )
          @?= False,
      -- The dispute must come back to the SAME address, which is read off the input being spent.
      -- Without this a resolution is a withdrawal: the NFT and the remaining ADA leave the script.
      testCase "returning the dispute to a wallet instead of its own script address is refused (D2)" $
        runResolve VerdictUpheld 0 (settling goodSettlement {disputeBackTo = strangerAddr})
          @?= False,
      -- The index in the redeemer is load-bearing: output 1 is the returned deposit, not the dispute.
      testCase "naming the wrong output index for the returned dispute is refused (D2)" $
        runResolve VerdictUpheld 1 goodResolveInfo @?= False,
      -- `geq` positively permits MORE, so leaving the deposit inside the dispute output is accepted:
      -- D2 is a floor, not an exact amount, and D4 then has to be funded from somewhere else — which
      -- this transaction does. Recorded because "less the deposit" reads like an equality and is not.
      testCase "returning MORE than the value less the deposit is accepted" $
        runResolve VerdictUpheld 0 (settling goodSettlement {disputeBackAs = disputeInputValue})
          @?= True,
      -- ---------------------------------------------------------------------------------------
      -- D2, SECOND ELEMENT: the UTxO being spent must actually BE this dispute.
      --
      -- Nothing else in the ResolveDispute arm authenticates the input — `isUnbackedDatum` guards the
      -- Cleanup arm only — so without this element anyone could park a copy of a real dispute's datum
      -- at the dispute address with no token behind it, and the admin's signature would write a
      -- verdict onto a UTxO that is not protocol state. The value here is conserved: neither the
      -- input nor the output holds the NFT, so this is not asking the ledger to do the impossible.
      testCase "a UTxO at the dispute address not holding the NFT its datum names is refused (D2)" $
        runResolve
          VerdictUpheld
          0
          (settling goodSettlement {disputeBackAs = minLvValue})
            {txInfoInputs = [disputeInputWith (V1.lovelaceValue (Lovelace (minUTxOLv + depositLv)))]}
          @?= False,
      -- ---------------------------------------------------------------------------------------
      -- D4: the deposit comes back, to the address fixed in the datum, on either verdict.
      --
      -- No deposit output at all, which the record cannot say either: it always builds two outputs.
      testCase "resolving without returning the deposit at all is refused (D4)" $
        runResolve
          VerdictUpheld
          0
          goodResolveInfo {txInfoOutputs = [resolvedOutputOf VerdictUpheld resolvedOutputValue disputesAddr]}
          @?= False,
      -- Paid, but to whoever built the transaction. D1 says that is the oracle admin, so this is the
      -- shape in which the admin pockets a disputer's deposit.
      testCase "returning the deposit to an address other than the disputer's is refused (D4)" $
        runResolve VerdictUpheld 0 (settling goodSettlement {depositPaidTo = strangerAddr})
          @?= False,
      testCase "returning one lovelace less than the recorded deposit is refused (D4)" $
        runResolve VerdictUpheld 0 (settling goodSettlement {depositPaid = depositLv - 1})
          @?= False,
      -- D4 is an `any` over the outputs, so the deposit's POSITION is free. Pinned because the
      -- obvious "hardening" is to demand it at an index, and the sound fix for the multiple-
      -- satisfaction hole this `any` had was D6 instead — UnitTests.Satisfaction pins that half as a
      -- pure function of the input list.
      testCase "the deposit may be returned at any output position" $
        runResolve
          VerdictUpheld
          0
          goodResolveInfo
            { txInfoOutputs =
                [ resolvedOutputOf VerdictUpheld resolvedOutputValue disputesAddr,
                  lovelaceOutput 3_000_000 strangerAddr,
                  lovelaceOutput depositLv disputerAddr
                ]
            }
          @?= True,
      -- And `geq` again: overpaying the disputer is their good luck, not the protocol's business.
      testCase "returning more than the recorded deposit is accepted" $
        runResolve VerdictUpheld 0 (settling goodSettlement {depositPaid = depositLv + 1})
          @?= True
    ]

-------------------------------------------------------------------------------

-- * @D9@: the exit that needs no key

-------------------------------------------------------------------------------

-- | 'openDispute' with its clock already run out. @t 900@ is the EARLIEST deadline @D9@ can accept,
-- because it is where the validity range every transaction in this module carries begins.
staleDispute :: OnchainDispute
staleDispute = openDispute {disputeStaleAfter = t 900}

-- | An expiry of the given dispute, with the given reference inputs. Everything else is fixed and
-- valid: one input at the dispute address (@D6@), and the outputs the case supplies.
--
-- __The reference inputs are a parameter so that a case can prove they are IGNORED__, which is the
-- whole design of this arm: it reads no oracle, so there is no lever — not the pause, not the admin
-- key — on the exit that exists because the admin did not act.
runExpireWith :: [TxInInfo] -> OnchainDispute -> Integer -> [TxOut] -> Bool
runExpireWith refInputs dispute idx outs =
  let dat = mkCIP68Datum dispute metadataFixture []
      info =
        emptyTxInfo
          { txInfoInputs = [TxInInfo disputeInputRef (txOut disputesAddr disputeInputValue (inlineOf dat))],
            txInfoReferenceInputs = refInputs,
            txInfoOutputs = outs
          }
   in disputesLambda
        ( ScriptContext
            info
            (Redeemer (toBuiltinData (ExpireDispute idx)))
            (SpendingScript disputeInputRef (Just (Datum (toBuiltinData dat))))
        )

-- | No reference inputs and no signatories, which is the ordinary case for this arm.
runExpire :: OnchainDispute -> Integer -> [TxOut] -> Bool
runExpire = runExpireWith []

-- | What a correct expiry pays back: the dispute at output 0 carrying 'VerdictExpired' and less the
-- deposit, and the deposit at output 1 to the address the OPENER named.
expiryOutputs :: OnchainDispute -> [TxOut]
expiryOutputs dispute =
  [ expiredOutputOf dispute resolvedOutputValue disputesAddr,
    lovelaceOutput depositLv disputerAddr
  ]

expiredOutputOf :: OnchainDispute -> V1.Value -> Address -> TxOut
expiredOutputOf dispute val addr =
  txOut addr val (inlineOf (dat {extra = resolveDispute VerdictExpired dispute}))
  where
    dat = mkCIP68Datum dispute metadataFixture []

expireTests :: TestTree
expireTests =
  testGroup
    "expiring a stale dispute needs no key, and nothing before its deadline"
    [ -- THE POSITIVE CONTROL, and it asserts the design as much as the rule: no reference inputs and
      -- no signatories at all, so nothing here is reachable by the admin. If someone later adds an
      -- oracle read to this arm — a @D7@ for symmetry, say — this is the case that goes red, and it
      -- should, because a pause would then re-create the freeze D-A exists to break.
      --
      -- It is also the UPPER half of @D9@'s boundary: 'staleDispute''s deadline sits exactly at the
      -- validity range's lower bound, which `checkDateHasPassed` accepts because the whole range is
      -- then at or after it. The case below is the same transaction one millisecond later.
      testCase "a well-formed expiry validates, with no oracle and nobody's signature (D9 boundary)" $
        runExpire staleDispute 0 (expiryOutputs staleDispute) @?= True,
      testCase "one millisecond past that boundary it is not stale yet (D9)" $
        let early = openDispute {disputeStaleAfter = t 901}
         in runExpire early 0 (expiryOutputs early) @?= False,
      -- A dispute whose deadline is in the FUTURE is the ordinary case, and the one that matters:
      -- without @D9@ anyone could close any dispute the moment it opened.
      testCase "the fixture's own open dispute, 30 days out, cannot be expired (D9)" $
        runExpire openDispute 0 (expiryOutputs openDispute) @?= False,
      -- @D3@ on this arm, which is what keeps the clock from being a delete button: a dispute the
      -- admin already decided cannot be overwritten with "expired" once it goes stale.
      testCase "a dispute that already carries a verdict cannot be expired (D3)" $
        let decided = staleDispute {disputeVerdict = Just VerdictUpheld}
         in runExpire decided 0 (expiryOutputs decided) @?= False,
      -- @D2@ through the shared 'disputeClosesWith': the output datum has to say EXPIRED. Writing a
      -- finding instead would let a stranger record a verdict nobody reached.
      testCase "writing a finding instead of EXPIRED is refused (D2)" $
        runExpire
          staleDispute
          0
          [ txOut disputesAddr resolvedOutputValue (inlineOf (resolvedDatum VerdictUpheld)),
            lovelaceOutput depositLv disputerAddr
          ]
          @?= False,
      -- @D4@: the deposit goes to the address the OPENER named, not to whoever built the
      -- transaction. This is what makes a permissionless expiry harmless.
      testCase "paying the deposit to the caller instead of the opener is refused (D4)" $
        runExpire
          staleDispute
          0
          [ expiredOutputOf staleDispute resolvedOutputValue disputesAddr,
            lovelaceOutput depositLv strangerAddr
          ]
          @?= False,
      -- And the deliberate ASYMMETRY with @D7@. A paused oracle in the reference inputs changes
      -- nothing, because this arm never looks: an escape hatch the admin can close by pausing is
      -- not an escape hatch, and "pause plus a lost key" was the permanent freeze.
      testCase "a PAUSED oracle does not block an expiry, deliberately (no D7 here)" $
        runExpireWith
          [oracleRefInput oracleParamsFixture {opPaused = True}]
          staleDispute
          0
          (expiryOutputs staleDispute)
          @?= True
    ]

-- @D6@ is not re-tested here on purpose: since D-A it lives in 'disputeClosesWith', shared verbatim
-- with the resolve arm, and the resolve group above already pins it. That sharing is the reason this
-- note can be a note instead of a seventh case.

-------------------------------------------------------------------------------

-- * @Md2@, @Md3@ and @Md6@: opening a dispute

-------------------------------------------------------------------------------

disputeSeedRef :: TxOutRef
disputeSeedRef = txOutRefAt 2

-- | The dispute NFT the policy derives from the seed, and the user token it must NOT mint. Derived
-- with the policy's own two functions, so a change to either shows up as a failure here rather than
-- as a test that still agrees with itself.
mintedDisputeRefTN, mintedDisputeUserTN :: V1.TokenName
(mintedDisputeRefTN, mintedDisputeUserTN) = generateRefAndUserTN (nameFromTxOutRef disputeSeedRef)

mintedDisputeId :: AssetClass
mintedDisputeId = AssetClass (protocolCS, mintedDisputeRefTN)

-- | One input carrying all three things an opening needs: it IS the seed (@Md1@), it holds the
-- opener's user token (@Md3@), and it sits at the address the deposit returns to (@Md8@). Its value is
-- a parameter so an @Md3@ case can change what is spent without disturbing @Md1@ or @Md8@.
disputeSeedInput :: V1.Value -> TxInInfo
disputeSeedInput val = TxInInfo disputeSeedRef (txOut disputerAddr val NoOutputDatum)

-- | Ten ADA plus whatever token a case wants to prove the opener with.
withSpendingAda :: V1.Value -> V1.Value
withSpendingAda val = val <> V1.lovelaceValue (Lovelace 10_000_000)

-- | What @Md5@ requires: the dispute NFT, the min-UTxO and the deposit, under the datum the policy
-- builds. Takes @openedAt@ because that date lands in the datum, so an @Md6@ case has to move both or
-- @Md5@ refuses the context first and the case proves nothing.
openedDisputeOutput :: POSIXTime -> TxOut
openedDisputeOutput openedAt =
  txOut
    disputesAddr
    (V1.assetClassValue mintedDisputeId 1 <> V1.lovelaceValue (Lovelace (minUTxOLv + depositLv)))
    (inlineOf (mkCIP68Datum expectedDispute metadataFixture []))
  where
    expectedDispute =
      OnchainDispute
        { disputeId = mintedDisputeId,
          disputeTarget = targetId,
          disputeOpenedBy = openerId,
          disputeOpenedAt = openedAt,
          disputeDeposit = depositLv,
          disputeDepositTo = disputerAddr,
          disputeOracleToken = oracleAC,
          -- The arithmetic the policy does, from this module's own oracle fixture.
          disputeStaleAfter = openedAt + POSIXTime 2_592_000_000,
          disputeVerdict = Nothing
        }

goodOpenDisputeInfo :: POSIXTime -> TxInfo
goodOpenDisputeInfo openedAt =
  emptyTxInfo
    { txInfoInputs = [disputeSeedInput (withSpendingAda (V1.assetClassValue (deriveUserFromRefAC openerId) 1))],
      txInfoReferenceInputs = [oracleRefInput oracleParamsFixture],
      txInfoOutputs = [openedDisputeOutput openedAt],
      txInfoMint = mintOne mintedDisputeId
    }

runOpenDispute :: POSIXTime -> TxInfo -> Bool
runOpenDispute openedAt info =
  mintingPolicyLambda
    protocolParamsFixture
    ( ScriptContext
        info
        ( Redeemer
            (toBuiltinData (OpenDispute disputeSeedRef targetId openerId disputerAddr metadataFixture openedAt 0))
        )
        (MintingScript protocolCS)
    )

openDisputeMintTests :: TestTree
openDisputeMintTests =
  testGroup
    "opening a dispute mints one NFT, proves the opener, and dates itself"
    [ testCase "a well-formed dispute opening validates" $
        runOpenDispute nowT (goodOpenDisputeInfo nowT) @?= True,
      -- ---------------------------------------------------------------------------------------
      -- Md2: just the dispute's REF NFT, and nothing burned.
      --
      -- Minting the matching user token alongside is the shape the handler's own Haddock rules out: a
      -- user token is authority to do something, and there is nothing a dispute's holder may do. One
      -- minted anyway later reads as a capability somebody can look for.
      testCase "minting the dispute's user token alongside its ref NFT is refused (Md2)" $
        runOpenDispute
          nowT
          (goodOpenDisputeInfo nowT)
            {txInfoMint = mintOf [(protocolCS, [(mintedDisputeRefTN, 1), (mintedDisputeUserTN, 1)])]}
          @?= False,
      -- Two of the NFT is not an NFT. The output is left alone and Md5's `geq` accepts it, so this is
      -- Md2's quantity half on its own.
      testCase "minting two of the dispute NFT is refused (Md2)" $
        runOpenDispute nowT (goodOpenDisputeInfo nowT) {txInfoMint = mintOf [(protocolCS, [(mintedDisputeRefTN, 2)])]}
          @?= False,
      -- The burn half, isolated: the minted side is exactly right and something else is destroyed in
      -- the same transaction. Nothing in this protocol has a burn path, so this conjunct is what says
      -- a transaction may not carry one.
      testCase "burning anything while opening a dispute is refused (Md2)" $
        runOpenDispute
          nowT
          (goodOpenDisputeInfo nowT)
            { txInfoMint =
                mintOf [(protocolCS, [(mintedDisputeRefTN, 1)]), (otherCS, [(V1.TokenName "burnt", -1)])]
            }
          @?= False,
      -- ---------------------------------------------------------------------------------------
      -- Md3: the opener is proven by spending the user token derived from `openedBy`.
      testCase "opening a dispute without spending the opener's user token is refused (Md3)" $
        runOpenDispute
          nowT
          (goodOpenDisputeInfo nowT)
            {txInfoInputs = [disputeSeedInput (V1.lovelaceValue (Lovelace 10_000_000))]}
          @?= False,
      -- Holding SOME profile's user token is not holding THIS one's. Without this, anybody with any
      -- profile could open a dispute recorded as having been opened by somebody else.
      testCase "spending another profile's user token does not prove the opener (Md3)" $
        runOpenDispute
          nowT
          (goodOpenDisputeInfo nowT)
            { txInfoInputs =
                [disputeSeedInput (withSpendingAda (V1.assetClassValue (deriveUserFromRefAC otherProfileId) 1))]
            }
          @?= False,
      -- And the REFERENCE token is not the user token, which is the direction of the derivation. A
      -- profile's ref token lives locked at the Profiles Validator and is state, not authority; this
      -- is the case that would pass if `deriveUserFromRefAC` were ever dropped from the check.
      testCase "spending the opener's REF token instead of its user token is refused (Md3)" $
        runOpenDispute
          nowT
          (goodOpenDisputeInfo nowT)
            {txInfoInputs = [disputeSeedInput (withSpendingAda (V1.assetClassValue openerId 1))]}
          @?= False,
      -- ---------------------------------------------------------------------------------------
      -- Md6: the open date is contained in the transaction's validity interval.
      --
      -- Each of these moves the date in the REDEEMER and in the expected output datum together, so
      -- Md5 stays satisfied and Md6 is the only conjunct left to fail. That is the whole reason
      -- `goodOpenDisputeInfo` takes the date instead of fixing it.
      testCase "back-dating a dispute's open date is refused (Md6)" $
        runOpenDispute (t 10) (goodOpenDisputeInfo (t 10)) @?= False,
      testCase "future-dating a dispute's open date is refused (Md6)" $
        runOpenDispute (t 5000) (goodOpenDisputeInfo (t 5000)) @?= False,
      -- The width half, through the lambda: an interval finite at both ends and simply very wide
      -- contains any date the attacker likes, and the ledger accepts it because the current slot lies
      -- inside it. UnitTests.OracleRules pins containment, finiteness, width and the exclusive-bound
      -- closures on the function itself; what this case adds is that Md6 calls the version with the
      -- width check in it, which no test of the function can say.
      testCase "a wide but finite validity interval cannot date a dispute freely (Md6)" $
        runOpenDispute (t 0) (goodOpenDisputeInfo (t 0)) {txInfoValidRange = interval (t 0) (maxDateWindow + 1)}
          @?= False
    ]

-------------------------------------------------------------------------------

-- * @Mj@: issuing an attestation mints just the attestation NFT

-------------------------------------------------------------------------------

attSeedRef :: TxOutRef
attSeedRef = txOutRefAt 3

mintedAttRefTN :: V1.TokenName
mintedAttRefTN = fst (generateRefAndUserTN (nameFromTxOutRef attSeedRef))

mintedAttId :: AssetClass
mintedAttId = AssetClass (protocolCS, mintedAttRefTN)

-- | One input that is the seed (@Mh@) and holds the issuer's user token (@Mf@).
attSeedInput :: TxInInfo
attSeedInput =
  TxInInfo
    attSeedRef
    (txOut strangerAddr (withSpendingAda (V1.assetClassValue (deriveUserFromRefAC issuerId) 1)) NoOutputDatum)

-- | What @Mk@ requires. @attestationIsAccepted@ is 'False' at issue; the subject accepts later.
attestationOutput :: TxOut
attestationOutput =
  txOut
    attestationsAddr
    (V1.assetClassValue mintedAttId 1 <> minLvValue)
    (inlineOf (mkCIP68Datum issuedAttestation metadataFixture []))
  where
    issuedAttestation =
      OnchainAttestation
        { attestationId = mintedAttId,
          attestationIssuer = issuerId,
          attestationSubject = subjectId,
          attestationKind = MilestoneDelivered,
          attestationDate = nowT,
          attestationPeriod = Nothing,
          attestationIsAccepted = False,
          attestationOracleToken = oracleAC
        }

goodAttestationInfo :: TxInfo
goodAttestationInfo =
  emptyTxInfo
    { txInfoInputs = [attSeedInput],
      txInfoReferenceInputs = [oracleRefInput oracleParamsFixture],
      txInfoOutputs = [attestationOutput],
      txInfoMint = mintOne mintedAttId
    }

runNewAttestation :: TxInfo -> Bool
runNewAttestation info =
  mintingPolicyLambda
    protocolParamsFixture
    ( ScriptContext
        info
        ( Redeemer
            ( toBuiltinData
                (NewAttestation attSeedRef metadataFixture [] subjectId issuerId MilestoneDelivered nowT Nothing 0)
            )
        )
        (MintingScript protocolCS)
    )

attestationMintTests :: TestTree
attestationMintTests =
  testGroup
    "issuing an attestation mints just the attestation NFT"
    [ testCase "a well-formed attestation issue validates" $
        runNewAttestation goodAttestationInfo @?= True,
      -- A second token of THIS policy in the same transaction. Mk pins only the output at the index
      -- the redeemer names, so without Mj the extra token is unconstrained: any name under the
      -- protocol's symbol, paid anywhere, and every reader of this symbol has to treat it as protocol
      -- state.
      testCase "minting a second token of this policy alongside the attestation is refused (Mj)" $
        runNewAttestation
          goodAttestationInfo
            {txInfoMint = mintOf [(protocolCS, [(mintedAttRefTN, 1), (V1.TokenName "extra", 1)])]}
          @?= False,
      -- Another policy's token is just as refused: Mj compares the WHOLE minted value, not this
      -- policy's share of it.
      testCase "minting another policy's token alongside the attestation is refused (Mj)" $
        runNewAttestation
          goodAttestationInfo
            {txInfoMint = mintOf [(protocolCS, [(mintedAttRefTN, 1)]), (otherCS, [(V1.TokenName "rider", 1)])]}
          @?= False,
      testCase "minting two of the attestation NFT is refused (Mj)" $
        runNewAttestation goodAttestationInfo {txInfoMint = mintOf [(protocolCS, [(mintedAttRefTN, 2)])]}
          @?= False,
      -- The burn half on its own: the minted side is exactly the attestation NFT and the burned side
      -- is not empty.
      testCase "burning anything while issuing an attestation is refused (Mj)" $
        runNewAttestation
          goodAttestationInfo
            {txInfoMint = mintOf [(protocolCS, [(mintedAttRefTN, 1)]), (otherCS, [(V1.TokenName "burnt", -1)])]}
          @?= False
    ]

-------------------------------------------------------------------------------

-- * @O2@: the oracle comes back, at the index, with the datum the action computed

-------------------------------------------------------------------------------

oracleInputRef :: TxOutRef
oracleInputRef = txOutRefAt 4

oracleInputValue :: V1.Value
oracleInputValue = V1.assetClassValue oracleAC 1 <> minLvValue

-- | @OraclePause@ throughout, for two reasons: its result differs from its input in exactly one
-- field, so a stale output datum is a one-field lie; and @O5@ is vacuous for everything but
-- @OracleSetAdmin@, so it cannot be what refuses these contexts.
pausedParams :: OracleParams
pausedParams = applyOracleAdminAction OraclePause oracleParamsFixture

oracleUTxO :: OracleParams -> V1.Value -> Address -> TxOut
oracleUTxO params val addr = txOut addr val (inlineOf params)

goodOracleInfo :: TxInfo
goodOracleInfo =
  emptyTxInfo
    { txInfoInputs = [TxInInfo oracleInputRef (oracleUTxO oracleParamsFixture oracleInputValue oracleAddr)],
      txInfoOutputs = [oracleUTxO pausedParams oracleInputValue oracleAddr],
      txInfoSignatories = [adminPkh]
    }

runOracleUpdate :: Integer -> TxInfo -> Bool
runOracleUpdate idx info =
  oracleLambda
    ( ScriptContext
        info
        (Redeemer (toBuiltinData (OracleUpdate idx OraclePause)))
        (SpendingScript oracleInputRef (Just (Datum (toBuiltinData oracleParamsFixture))))
    )

oracleReturnTests :: TestTree
oracleReturnTests =
  testGroup
    "an oracle update returns the oracle with the datum it computed"
    [ testCase "a well-formed oracle update validates" $
        runOracleUpdate 0 goodOracleInfo @?= True,
      -- THE DATUM MUST BE THE COMPUTED ONE. O2 compares the output against
      -- `applyOracleAdminAction action currentParams`, which is what makes every field the action
      -- does not touch provably unchanged. Returning the params as they were is the pause that does
      -- not pause.
      testCase "returning the oracle datum unchanged by the action is refused (O2)" $
        runOracleUpdate 0 goodOracleInfo {txInfoOutputs = [oracleUTxO oracleParamsFixture oracleInputValue oracleAddr]}
          @?= False,
      -- The sharper version, and the reason O2 compares a whole datum rather than re-deriving the
      -- field the action names: this output IS paused, so the action was performed — and it also
      -- hands the oracle to somebody else. Only the whole-datum comparison refuses it, which is what
      -- stops a repricing or a pause from carrying a rotation along with it.
      testCase "a correctly paused datum that also rotates the admin is refused (O2)" $
        runOracleUpdate
          0
          goodOracleInfo
            {txInfoOutputs = [oracleUTxO pausedParams {opAdminPkh = strangerPkh} oracleInputValue oracleAddr]}
          @?= False,
      -- The NFT must stay locked, which is what "at least the same value" is for: drop it and the
      -- oracle ceases to exist, and every `readOracleParams` in the protocol traces K1 for ever.
      testCase "returning the oracle without its NFT is refused (O2)" $
        runOracleUpdate 0 goodOracleInfo {txInfoOutputs = [oracleUTxO pausedParams minLvValue oracleAddr]}
          @?= False,
      -- The same address, or the oracle leaves the script with the admin's own signature on it.
      testCase "returning the oracle to a wallet instead of its own address is refused (O2)" $
        runOracleUpdate 0 goodOracleInfo {txInfoOutputs = [oracleUTxO pausedParams oracleInputValue strangerAddr]}
          @?= False,
      -- At the index the redeemer names: output 0 here is somebody's change.
      testCase "naming the wrong output index for the returned oracle is refused (O2)" $
        runOracleUpdate 0 goodOracleInfo {txInfoOutputs = oracleAtSecondOutput}
          @?= False,
      testCase "the same transaction with the oracle's actual index named is accepted" $
        runOracleUpdate 1 goodOracleInfo {txInfoOutputs = oracleAtSecondOutput}
          @?= True,
      -- `geq` and not `==`, deliberately: the balancer may add min-ADA to the oracle output, and a
      -- strict equality here would make an ordinary balanced transaction unsubmittable.
      testCase "the balancer may add lovelace to the returned oracle" $
        runOracleUpdate
          0
          goodOracleInfo
            { txInfoOutputs =
                [oracleUTxO pausedParams (oracleInputValue <> V1.lovelaceValue (Lovelace 1_000_000)) oracleAddr]
            }
          @?= True
    ]
  where
    oracleAtSecondOutput =
      [ lovelaceOutput 3_000_000 strangerAddr,
        oracleUTxO pausedParams oracleInputValue oracleAddr
      ]
