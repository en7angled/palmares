{-# LANGUAGE OverloadedStrings #-}

-- | The metadata byte limits, and the whole-address comparison the three mint paths make.
--
-- __Seven trace codes that no test could kill.__ A mutation run found @Mm@, @Mp4@, @Md7@, @P4@,
-- @Mk@, @Mp5@ and @Md5@ deletable without a single case going red. 'Test.Fixtures' even carries
-- 'profileDataOverLongName', built for the first four and referenced by nothing.
--
-- __Why these cases build a 'ScriptContext' instead of calling the predicate.__ @UnitTests.MintInputs@
-- pins 'Palmares.Onchain.CIP68.validateOtherMetadata' as a pure function and that is the right shape
-- for a rule that lives in one function. It cannot close this hole: a conjunct is guarded by
-- @traceIfFalse \"Mm\"@ in the validator, and asserting things about 'validateMetadataFields' stays
-- green when that line is deleted — the function is still there, nothing calls it, and the test never
-- notices. The only assertion that goes red on the deletion is one about the validator's own answer.
--
-- __And that forces a COMPLETE context, not merely a reachable one.__ The conjuncts are @&&@-chained,
-- so a context in which only the checks up to the one under test pass produces 'False' either way:
-- delete the conjunct and the next failing one answers for it. Each builder below is therefore an
-- otherwise-valid transaction for its redeemer, varying only what its own case is about, and each
-- group opens with a baseline asserting 'True'. The baseline is not decoration — it is the whole
-- proof that the negatives below it fail for the stated reason and not for a typo sixteen fields away.
--
-- __Group 2 pins a live design question, deliberately on the side of today's code.__
-- 'Palmares.Onchain.Utils.isTxOutAtIndexWithDatumMinValueAndAddress' compares @address ==
-- txOutAddress@, the WHOLE address, while the expected address comes from
-- @PlutusLedgerApi.V1.Address.scriptHashAddress@, which builds it with no staking credential. So a
-- state output at the right script carrying a stake credential fails the mint. Whether it should is
-- undecided in this project; these cases record that it does, because a case asserting the arguable
-- future behaviour would be red against correct code and would be deleted rather than read.
module UnitTests.MetadataLimits (tests) where

import Palmares.Onchain.CIP68
  ( CIP68Datum,
    MetadataFields (..),
    deriveUserFromRefAC,
    generateRefAndUserTN,
    mkCIP68Datum,
    updateCIP68DatumMetadata,
  )
import Palmares.Onchain.Protocol.Types
  ( AttestationKind (Endorsement),
    OnchainAttestation (..),
    OnchainDispute (..),
    OnchainProfile (..),
    OnchainProfileKind (Community),
    OracleParams (..),
    ProtocolParams (..),
  )
import Palmares.Onchain.Utils (nameFromTxOutRef)
import Palmares.Onchain.Validators.MintingPolicy (MintingRedeemer (..), mintingPolicyLambda)
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile), profilesLambda)
import Palmares.TxBuilding.Conversions (profileDataToMetadataFields)
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Interval (interval)
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (PubKeyCredential),
    Datum (..),
    OutputDatum (NoOutputDatum, OutputDatum),
    POSIXTime (..),
    POSIXTimeRange,
    PubKeyHash (..),
    Redeemer (..),
    ScriptContext (..),
    ScriptHash (..),
    ScriptInfo (MintingScript, SpendingScript),
    StakingCredential (StakingHash),
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
import Test.Fixtures (drepProfileData, profileDataOverLongName)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "metadata limits and output address"
    [ metadataFieldTests,
      outputAddressTests
    ]

-------------------------------------------------------------------------------

-- * Group 1: @Mm@, @Mp4@, @Md7@, @P4@ — the metadata field byte limits

-------------------------------------------------------------------------------

-- | Every path that writes 'MetadataFields' into a permanent datum bounds them, and each path has its
-- own code for it. The datum cannot be changed afterwards — nothing in this protocol burns, and
-- @updateCIP68DatumMetadata@ rewrites only @description@ and @image@ — so an oversized field is
-- permanent, and past the datum limit it is an unspendable UTxO.
metadataFieldTests :: TestTree
metadataFieldTests =
  testGroup
    "metadata field byte limits"
    [ -- THE BASELINES. Each says: this context is a transaction the validator accepts. Without them
      -- every negative below could be passing on an unrelated refusal, which is exactly how these
      -- seven codes came to have no test at all.
      testCase "baseline: an otherwise-valid attestation mint is accepted" $
        mintingPolicyLambda protoParams (attestationMint okFields attestationsAddr) @?= True,
      testCase "baseline: an otherwise-valid profile mint is accepted" $
        mintingPolicyLambda protoParams (profileMint okFields profilesAddr) @?= True,
      testCase "baseline: an otherwise-valid dispute open is accepted" $
        mintingPolicyLambda protoParams (disputeOpen okFields disputesAddr) @?= True,
      testCase "baseline: an otherwise-valid profile update is accepted" $
        profilesLambda (profileUpdate okFields) @?= True,
      -- Mm. The attestation path. `Mk` after it compares the whole datum against the output, and the
      -- builder puts the SAME oversized metadata in both, so the only thing left for the mint to
      -- refuse is the size — and with the `Mm` conjunct deleted the mint succeeds.
      testCase "Mm: an attestation whose name is one byte over the limit is refused" $
        mintingPolicyLambda protoParams (attestationMint overLongName attestationsAddr) @?= False,
      -- Mp4. The profile path, once per field, because `validateMetadataFields` is three `&&`-chained
      -- length comparisons and one deleted comparison is one unbounded field. Each case leaves the
      -- other two fields well inside their limits, so it can only fail on its own.
      testCase "Mp4: a profile whose name is one byte over the limit is refused" $
        mintingPolicyLambda protoParams (profileMint overLongName profilesAddr) @?= False,
      testCase "Mp4: a profile whose description is one byte over the limit is refused" $
        mintingPolicyLambda protoParams (profileMint overLongDescription profilesAddr) @?= False,
      testCase "Mp4: a profile whose image URI is one byte over the limit is refused" $
        mintingPolicyLambda protoParams (profileMint overLongImage profilesAddr) @?= False,
      -- And the other side of each boundary, in the one place a full context can state it: exactly
      -- 128 / 1024 / 256 bytes is accepted. An off-by-one in any of the three limits fails here while
      -- the three cases above still pass, which is what makes this pair worth keeping.
      testCase "Mp4: a profile with every field exactly at its limit is accepted" $
        mintingPolicyLambda protoParams (profileMint atTheLimit profilesAddr) @?= True,
      -- Md7. The dispute path. Last conjunct of its handler, so `Md5` and `Md6` before it both have
      -- to pass for this to be about the metadata — see the builder.
      testCase "Md7: opening a dispute whose name is one byte over the limit is refused" $
        mintingPolicyLambda protoParams (disputeOpen overLongName disputesAddr) @?= False,
      -- P4. The update path, and the one case where the refused field is one the update would have
      -- THROWN AWAY: `updateCIP68DatumMetadata` writes `description` and `image` and leaves `name`
      -- alone, so an over-long name never reaches a datum. `P4` refuses it anyway, which is the
      -- behaviour being recorded here rather than endorsed — and it is why `P5` still passes with the
      -- `P4` conjunct deleted, so this case is a clean kill for it.
      testCase "P4: updating a profile with a name one byte over the limit is refused" $
        profilesLambda (profileUpdate overLongName) @?= False,
      testCase "P4: updating a profile with a description one byte over the limit is refused" $
        profilesLambda (profileUpdate overLongDescription) @?= False
    ]

-------------------------------------------------------------------------------

-- * Group 2: @Mk@, @Mp5@, @Md5@ — the output address is compared WHOLE

-------------------------------------------------------------------------------

-- | A state output must sit at the validator's address, and the comparison is on the whole 'Address'.
--
-- The expected address is @scriptHashAddress sh@, whose staking half is 'Nothing'. The actual output's
-- address is whatever the transaction built. So the same script with a stake credential attached is a
-- different address and the mint is refused.
--
-- __These cases vary the staking half and nothing else__ — 'staked' reuses the payment credential it
-- is handed — so each one isolates the address comparison from the datum and the value, which the
-- same conjunct also checks. The matching baseline in 'metadataFieldTests' is the unstaked form of
-- the identical transaction.
outputAddressTests :: TestTree
outputAddressTests =
  testGroup
    "a protocol output's address is compared whole, staking half included"
    [ testCase "Mk: an attestation locked at the attestations script WITH a stake credential is refused" $
        mintingPolicyLambda protoParams (attestationMint okFields (staked attestationsAddr)) @?= False,
      testCase "Mp5: a profile locked at the profiles script WITH a stake credential is refused" $
        mintingPolicyLambda protoParams (profileMint okFields (staked profilesAddr)) @?= False,
      testCase "Md5: a dispute locked at the disputes script WITH a stake credential is refused" $
        mintingPolicyLambda protoParams (disputeOpen okFields (staked disputesAddr)) @?= False
    ]

-------------------------------------------------------------------------------

-- * The protocol these contexts are built against

-------------------------------------------------------------------------------

policyCS :: V1.CurrencySymbol
policyCS = V1.CurrencySymbol "c0ffee"

profilesSH, attestationsSH, disputesSH :: ScriptHash
profilesSH = ScriptHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1"
attestationsSH = ScriptHash "\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2"
disputesSH = ScriptHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"

profilesAddr, attestationsAddr, disputesAddr :: Address
profilesAddr = V1.scriptHashAddress profilesSH
attestationsAddr = V1.scriptHashAddress attestationsSH
disputesAddr = V1.scriptHashAddress disputesSH

-- The same payment credential with a stake credential bolted on. Keeping the payment half is what
-- makes the Group 2 cases about the staking half and nothing else.
staked :: Address -> Address
staked (Address payment _) = Address payment (Just (StakingHash (PubKeyCredential walletPkh)))

walletPkh :: PubKeyHash
walletPkh = PubKeyHash "\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9\9"

walletAddr :: Address
walletAddr = Address (PubKeyCredential walletPkh) Nothing

oracleAC :: V1.AssetClass
oracleAC = V1.AssetClass (V1.CurrencySymbol "decafe", V1.TokenName "oracle")

protoParams :: ProtocolParams
protoParams =
  ProtocolParams
    { profilesValidatorScriptHash = profilesSH,
      attestationsValidatorScriptHash = attestationsSH,
      disputesValidatorScriptHash = disputesSH,
      oracleToken = oracleAC
    }

-- Unpaused, and with NO fee config: `checkFee` returns True without the transaction carrying a fee
-- output, so neither `M0` nor `K2` can be the reason any case here fails.
oracleParams :: OracleParams
oracleParams =
  OracleParams
    { opAdminPkh = walletPkh,
      opPaused = False,
      opFeeConfig = Nothing,
      opMinUTxOValue = 2000000,
      opDisputeDeposit = 5000000
    }

minLv :: V1.Value
minLv = V1.lovelaceValue (V1.Lovelace (opMinUTxOValue oracleParams))

-- The oracle every path reads as a reference input. Its address is irrelevant: `readOracleParams`
-- selects on the NFT, and it traces `K1` — an error, not a False — if no reference input carries it.
oracleRefInput :: TxInInfo
oracleRefInput =
  TxInInfo
    (seedRef 90)
    (utxo walletAddr (V1.assetClassValue oracleAC 1 <> minLv) (inlineOf oracleParams))

-------------------------------------------------------------------------------

-- * Context plumbing

-------------------------------------------------------------------------------

-- Every field a V3 `TxInfo` has, with the oracle already in place. A builder overrides only the two
-- or three fields its own redeemer is about, so a mistake in the other thirteen cannot be what makes
-- a case go red.
baseTxInfo :: TxInfo
baseTxInfo =
  TxInfo
    { txInfoInputs = [],
      txInfoReferenceInputs = [oracleRefInput],
      txInfoOutputs = [],
      txInfoFee = V1.Lovelace 200000,
      txInfoMint = emptyMintValue,
      txInfoTxCerts = [],
      txInfoWdrl = AssocMap.empty,
      txInfoValidRange = validRange,
      txInfoSignatories = [],
      txInfoRedeemers = AssocMap.empty,
      txInfoData = AssocMap.empty,
      txInfoId = TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
      txInfoVotes = AssocMap.empty,
      txInfoProposalProcedures = [],
      txInfoCurrentTreasuryAmount = Nothing,
      txInfoTreasuryDonation = Nothing
    }

-- Ten minutes wide and bounded at both ends, which is what `checkDateInRange` requires: finite bounds
-- and a width within `maxDateWindow`. `recordedAt` below sits inside it.
validRange :: POSIXTimeRange
validRange = interval (POSIXTime 1700000000000) (POSIXTime 1700000600000)

recordedAt :: POSIXTime
recordedAt = POSIXTime 1700000001000

seedRef :: Integer -> TxOutRef
seedRef = TxOutRef (TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\1")

utxo :: Address -> V1.Value -> OutputDatum -> TxOut
utxo addr val dat =
  TxOut
    { txOutAddress = addr,
      txOutValue = val,
      txOutDatum = dat,
      txOutReferenceScript = Nothing
    }

inlineOf :: (ToData a) => a -> OutputDatum
inlineOf = OutputDatum . Datum . toBuiltinData

-- `Value` and `MintValue` are both newtypes over the same map, so this is the conversion the library
-- does not export. `mintValueMinted` takes the positive quantities back out, which for a value built
-- from `assetClassValue _ 1` is the value itself, and `mintValueBurned` is then empty — which is what
-- the `Mj`/`Mp2`/`Md2` exact-mint checks compare against.
mintOf :: V1.Value -> MintValue
mintOf = UnsafeMintValue . V1.getValue

-- A profile id has to be one of THIS protocol's CIP-67 reference tokens (`Mg`, `Md4`), which is what
-- building it through the protocol's own generator guarantees.
refIdFromSeed :: BuiltinByteString -> V1.AssetClass
refIdFromSeed seed = V1.AssetClass (policyCS, fst (generateRefAndUserTN seed))

subjectId, issuerId, targetId :: V1.AssetClass
subjectId = refIdFromSeed "subject"
issuerId = refIdFromSeed "issuer"
targetId = refIdFromSeed "target"

-------------------------------------------------------------------------------

-- * The four contexts

-------------------------------------------------------------------------------

-- | A complete @NewAttestation@ mint: @M0@, the fee gate, @Ml@, @Mn@, @Mf@, @Mg@, @Mh@, @Mj@ and
-- @Mk@ all pass as given. The two parameters are the only things the cases vary — the metadata the
-- redeemer carries, and the address the state output is locked at.
attestationMint :: MetadataFields -> Address -> ScriptContext
attestationMint fields outAddr =
  ScriptContext txInfo (Redeemer (toBuiltinData redeemer)) (MintingScript policyCS)
  where
    seed = seedRef 1
    attId = V1.AssetClass (policyCS, fst (generateRefAndUserTN (nameFromTxOutRef seed)))
    attNFT = V1.assetClassValue attId 1
    redeemer = NewAttestation seed fields [] subjectId issuerId Endorsement recordedAt Nothing 0
    -- The datum the handler computes from that redeemer, rebuilt here so `Mk` sees a byte-identical
    -- output. That is also what keeps the `Mm` case honest: the oversized metadata goes into BOTH, so
    -- `Mk` is not what refuses the transaction.
    datum =
      mkCIP68Datum
        OnchainAttestation
          { attestationId = attId,
            attestationIssuer = issuerId,
            attestationSubject = subjectId,
            attestationKind = Endorsement,
            attestationDate = recordedAt,
            attestationPeriod = Nothing,
            attestationIsAccepted = False
          }
        fields
        []
    txInfo =
      baseTxInfo
        { -- One input does both jobs: it is the seed `Mh` wants spent, and it holds the issuer's user
          -- token, which is what `Mf` looks for in `valueSpent`.
          txInfoInputs =
            [ TxInInfo
                seed
                (utxo walletAddr (V1.assetClassValue (deriveUserFromRefAC issuerId) 1 <> minLv) NoOutputDatum)
            ],
          txInfoMint = mintOf attNFT,
          txInfoOutputs = [utxo outAddr (attNFT <> minLv) (inlineOf datum)]
        }

-- | A complete @MintProfile@ mint: @Mp1@, @Mp2@, @Mp3@, @Mp5@ and @Mp6@ all pass as given.
--
-- The claimed credential is 'Nothing' on purpose. A profile that claims nothing has nothing to prove,
-- so @Mp3@ passes without this context having to witness a credential — which keeps the case about
-- the metadata and not about 'Palmares.Onchain.Utils.checkCredentialControl', whose own rules
-- @UnitTests.Claim@ already pins.
profileMint :: MetadataFields -> Address -> ScriptContext
profileMint fields outAddr =
  ScriptContext txInfo (Redeemer (toBuiltinData redeemer)) (MintingScript policyCS)
  where
    seed = seedRef 2
    (refTN, userTN) = generateRefAndUserTN (nameFromTxOutRef seed)
    refAC = V1.AssetClass (policyCS, refTN)
    refNFT = V1.assetClassValue refAC 1
    userNFT = V1.assetClassValue (V1.AssetClass (policyCS, userTN)) 1
    redeemer = MintProfile seed Community Nothing fields 0
    datum =
      mkCIP68Datum
        OnchainProfile
          { profileId = refAC,
            profileKind = Community,
            profileCredential = Nothing,
            protocolParams = protoParams
          }
        fields
        []
    txInfo =
      baseTxInfo
        { txInfoInputs = [TxInInfo seed (utxo walletAddr minLv NoOutputDatum)],
          txInfoMint = mintOf (refNFT <> userNFT),
          -- The user token is minted and deliberately NOT paid into the state output: `Mp6` refuses
          -- the authority token locked beside the state it authorises.
          txInfoOutputs = [utxo outAddr (refNFT <> minLv) (inlineOf datum)]
        }

-- | A complete @OpenDispute@ mint: every conjunct from @Md1@ to @Md8@ passes as given.
--
-- @Md7@ is the LAST conjunct of its handler, so reaching it needs @Md5@ (the whole output) and @Md6@
-- (the open date) to pass first — which is why the output below carries the deposit as well as the
-- NFT and the min-ADA, and why 'recordedAt', which the redeemer passes as @openedAt@, sits inside
-- 'validRange'.
disputeOpen :: MetadataFields -> Address -> ScriptContext
disputeOpen fields outAddr =
  ScriptContext txInfo (Redeemer (toBuiltinData redeemer)) (MintingScript policyCS)
  where
    seed = seedRef 3
    dispId = V1.AssetClass (policyCS, fst (generateRefAndUserTN (nameFromTxOutRef seed)))
    dispNFT = V1.assetClassValue dispId 1
    deposit = opDisputeDeposit oracleParams
    redeemer = OpenDispute seed targetId issuerId walletAddr fields recordedAt 0
    datum =
      mkCIP68Datum
        OnchainDispute
          { disputeId = dispId,
            disputeTarget = targetId,
            disputeOpenedBy = issuerId,
            disputeOpenedAt = recordedAt,
            disputeDeposit = deposit,
            disputeDepositTo = walletAddr,
            disputeOracleToken = oracleAC,
            disputeVerdict = Nothing
          }
        fields
        []
    txInfo =
      baseTxInfo
        { -- `Md3` wants the opener's user token in `valueSpent` and `Md8` wants `disputeDepositTo` to
          -- be an address this transaction spends from. One input at the wallet address does both,
          -- and it is the seed `Md1` wants spent.
          txInfoInputs =
            [ TxInInfo
                seed
                (utxo walletAddr (V1.assetClassValue (deriveUserFromRefAC issuerId) 1 <> minLv) NoOutputDatum)
            ],
          txInfoMint = mintOf dispNFT,
          -- The deposit is part of the locked value, not a separate payment.
          txInfoOutputs =
            [utxo outAddr (dispNFT <> minLv <> V1.lovelaceValue (V1.Lovelace deposit)) (inlineOf datum)]
        }

-- | A complete @UpdateProfile@ spend: @P6@, @P2@, @P3@ and @P5@ all pass as given.
--
-- @P5@ compares the output against @updateCIP68DatumMetadata newFields oldDatum@, so the output datum
-- is computed exactly the way the validator computes it. That is what isolates @P4@: with the @P4@
-- conjunct deleted, @P5@ still matches and the spend succeeds.
profileUpdate :: MetadataFields -> ScriptContext
profileUpdate newFields =
  ScriptContext
    txInfo
    (Redeemer (toBuiltinData (UpdateProfile newFields 0)))
    (SpendingScript ownRef (Just (Datum (toBuiltinData oldDatum))))
  where
    ownRef = seedRef 4
    (refTN, userTN) = generateRefAndUserTN "existing-profile"
    refAC = V1.AssetClass (policyCS, refTN)
    ownValue = V1.assetClassValue refAC 1 <> minLv
    oldDatum :: CIP68Datum OnchainProfile
    oldDatum =
      mkCIP68Datum
        OnchainProfile
          { profileId = refAC,
            profileKind = Community,
            profileCredential = Nothing,
            protocolParams = protoParams
          }
        okFields
        []
    txInfo =
      baseTxInfo
        { txInfoInputs =
            [ TxInInfo ownRef (utxo profilesAddr ownValue (inlineOf oldDatum)),
              -- `P3` reads `valueSpent`, so the authority token sits in an ordinary wallet input —
              -- where it belongs, and out of the value `P5` then requires to be re-locked.
              TxInInfo
                (seedRef 5)
                (utxo walletAddr (V1.assetClassValue (V1.AssetClass (policyCS, userTN)) 1 <> minLv) NoOutputDatum)
            ],
          txInfoOutputs =
            [utxo profilesAddr ownValue (inlineOf (updateCIP68DatumMetadata newFields oldDatum))]
        }

-------------------------------------------------------------------------------

-- * Metadata

-------------------------------------------------------------------------------

-- What every baseline carries: short, well inside all three limits, so a baseline that fails is a
-- fault in the context rather than in the field sizes.
okFields :: MetadataFields
okFields = profileDataToMetadataFields drepProfileData

-- The fixture 'Test.Fixtures' built for exactly these four codes and no test ever used: a 129-byte
-- name with the description and image URI well inside theirs. Usable as it stands.
overLongName :: MetadataFields
overLongName = profileDataToMetadataFields profileDataOverLongName

-- The other two fields, one byte over, built here rather than taken from 'Test.Fixtures'.
--
-- __Not a style preference.__ @Test.Fixtures.maxLengthImageURI@ is 255 bytes, not the 256 its comment
-- claims: @\"ipfs:\/\/Qm\"@ is nine characters and the arithmetic counts it as ten. So
-- @profileDataMaxLengthMetadata@ sits one byte UNDER the image limit, and the \"exactly at its limit\"
-- case above would not have been at the limit. Fixing the fixture is somebody else's edit; stating
-- the three numbers here keeps this module's boundary claims true either way.
bytes :: Integer -> BuiltinByteString
bytes n = foldr (\_ acc -> "a" <> acc) "" [1 .. n]

fieldsWith :: BuiltinByteString -> BuiltinByteString -> BuiltinByteString -> MetadataFields
fieldsWith name description image =
  Metadata222
    { metadataName = name,
      metadataDescription = description,
      metadataImageURI = image
    }

atTheLimit, overLongDescription, overLongImage :: MetadataFields
atTheLimit = fieldsWith (bytes 128) (bytes 1024) (bytes 256)
overLongDescription = fieldsWith (bytes 1) (bytes 1025) (bytes 1)
overLongImage = fieldsWith (bytes 1) (bytes 1) (bytes 257)
