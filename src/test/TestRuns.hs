{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The emulator harness: deploy the protocol into a CLB ledger, then drive it through the same
-- 'Interaction' pipeline the HTTP services use.
--
-- __Why every runner goes through 'interactionToTxSkeleton'.__ A test that hand-builds a skeleton
-- proves the validator accepts that skeleton; it proves nothing about the transaction the service
-- would actually send. The runners below take an 'ActionType' and nothing else, so what they exercise
-- is the production path. The exceptions are the @malicious*@ builders, which exist precisely to send
-- a transaction no production path can produce.
--
-- __This module was inherited from the Belt System and is now trimmed to this protocol.__ It deployed
-- five spending validators into a seven-field context; two of those validators (Ranks, Memberships)
-- do not exist here, and the promotion-acceptance attack they existed to test is gone with them. What
-- survived is the shape: reference-script deployment, the one-shot oracle NFT, and the interaction
-- runners.
module TestRuns
  ( -- * Deployment
    deployValidators,
    userPlutusPkh,

    -- * Interaction runners
    profileInteraction,
    disputeInteraction,
    protocolInteraction,
    adminInteraction,

    -- * Griefing / dust
    sendDustToValidator,
    lockParsingDatumAt,
    sendAdaToAddress,

    -- * Malicious builders
    maliciousMintOracleNFTWithExtraToken,
    maliciousMintOracleNFTWrongName,
    maliciousOracleUpdate,
    maliciousClaimWithoutControl,
    maliciousMintProfileWithExtraToken,
    maliciousMintProfileWithBurn,
    maliciousIssueAttestation,
    maliciousDoubleAccept,
    maliciousResolveDispute,
  )
where

import Control.Monad (void)
import Control.Monad.Reader
import Data.Foldable.Extra
import Data.Maybe (fromMaybe)
import GHC.Stack
import GeniusYield.Test.Clb (sendSkeleton')
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder hiding (userAddresses)
import GeniusYield.TxBuilder.User qualified as User
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (AttestationType, DisputeVerdict, ProfileType)
import Palmares.Onchain.CIP68 (CIP68Datum (..), MetadataFields, mkCIP68Datum)
import Palmares.Onchain.Protocol.Types (OracleAdminAction, OracleParams (..))
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer (AcceptAttestation))
import Palmares.Onchain.Validators.DisputesValidator qualified as DisputesValidator (DisputesRedeemer (ResolveDispute))
import Palmares.Onchain.Validators.MintingPolicy (MintingRedeemer (MintProfile, NewAttestation))
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Conversions
  ( attestationTypeToOnchainAttestationKind,
    disputeVerdictToOnchainVerdict,
    profileTypeToOnchainProfileKind,
  )
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue, getDisputeDatumAndValue, queryOracleParams)
import Palmares.TxBuilding.Operations
  ( adminActionToOracleAdminAction,
    applyAdminAction,
    getOracleAndValiditySkeleton,
    getOracleFeeAndValiditySkeleton,
    spendUserNFTForProfile,
  )
import Palmares.TxBuilding.Skeletons
import Palmares.TxBuilding.Utils (pPOSIXTimeFromGYSlot, tnFromGYAssetClass, txOutRefToV3Plutus)
import Palmares.TxBuilding.Validators
import Palmares.Utils
import PlutusLedgerApi.V3 (PubKeyHash)
import PlutusLedgerApi.V3 qualified as V3
import PlutusTx (ToData)

------------------------------------------------------------------------------------------------

-- * Test Runs Helpers

------------------------------------------------------------------------------------------------

deployReferenceScriptRun :: (GYTxGameMonad m, HasCallStack) => GYScript PlutusV3 -> User -> User -> m (GYScriptHash, GYTxOutRef)
deployReferenceScriptRun validator fromWallet toWallet = asUser fromWallet $ do
  ref <- addRefScript (userChangeAddress toWallet) (validatorToScript validator)
  return (scriptHash validator, ref)

------------------------------------------------------------------------------------------------

-- * Test Runs

------------------------------------------------------------------------------------------------

-- | Deploy the whole protocol: four spending validators as reference scripts, the one-shot oracle
-- NFT with its initial params, then the minting policy compiled against that NFT.
--
-- The order is forced, not stylistic: the minting policy is parameterised by the oracle 'AssetClass',
-- so it cannot be compiled — let alone deployed — before the NFT exists.
deployValidators :: (GYTxGameMonad m, HasCallStack) => User -> m DeployedScriptsContext
deployValidators w = do
  -- Step 1: Deploy spending validators as reference scripts
  (pVhash, refProfilesValidator) <- deployReferenceScriptRun profilesValidatorGY w w
  (aVhash, refAttestationsValidator) <- deployReferenceScriptRun attestationsValidatorGY w w
  (dVhash, refDisputesValidator) <- deployReferenceScriptRun disputesValidatorGY w w
  (ovHash, refOracleValidator) <- deployReferenceScriptRun oracleValidatorGY w w

  -- Step 2: Mint oracle NFT and lock initial OracleParams at oracle validator
  oracleNFTAC <- mintTestOracleNFT w

  -- Step 3: Compile minting policy with the oracle NFT asset class and deploy
  let mpGY = compileMintingPolicy (assetClassToPlutus oracleNFTAC)
  (mphash, refMintingPolicy) <- deployReferenceScriptRun mpGY w w

  -- Log deployed script sizes for reporting. The gate that FAILS on a regression is
  -- 'UnitTests.ScriptSize'; this line is for reading the numbers off a test run.
  gyLogInfo' ("SCRIPTSIZE" :: GYLogNamespace) $
    cyanColorString $
      "SCRIPT_SIZES:\n"
        <> "  ProfilesValidator: "
        <> show profilesValidatorSize
        <> " bytes\n"
        <> "  AttestationsValidator: "
        <> show attestationsValidatorSize
        <> " bytes\n"
        <> "  DisputesValidator: "
        <> show disputesValidatorSize
        <> " bytes\n"
        <> "  OracleValidator: "
        <> show oracleValidatorSize
        <> " bytes\n"
        <> "  MintingPolicy: "
        <> show (mintingPolicySize (assetClassToPlutus oracleNFTAC))
        <> " bytes"

  return
    DeployedScriptsContext
      { profilesValidatorHashAndRef = (pVhash, refProfilesValidator),
        attestationsValidatorHashAndRef = (aVhash, refAttestationsValidator),
        disputesValidatorHashAndRef = (dVhash, refDisputesValidator),
        mintingPolicyHashAndRef = (mphash, refMintingPolicy),
        oracleValidatorHashAndRef = (ovHash, refOracleValidator),
        oracleNFTAssetClass = oracleNFTAC
      }

-- | Derive the Plutus PubKeyHash from a GeniusYield User's change address.
userPlutusPkh :: User -> PubKeyHash
userPlutusPkh u =
  case addressToPlutus (User.userChangeAddress u) of
    V3.Address (V3.PubKeyCredential pkh) _ -> pkh
    _ -> error "userPlutusPkh: expected PubKeyCredential"

-- | The initial oracle params every emulator test starts from.
--
-- 'opAdminPkh' must be a wallet that can actually sign, because the oracle validator checks the
-- signature on chain — a placeholder hash here would make every admin test unfailable for the wrong
-- reason. The other four are the deployment defaults: unpaused, no fees (the preprod configuration),
-- 1 ADA minimum for protocol state, 5 ADA to open a dispute.
initialOracleParamsFor :: User -> OracleParams
initialOracleParamsFor w =
  OracleParams
    { opAdminPkh = userPlutusPkh w,
      opPaused = False,
      opFeeConfig = Nothing,
      opMinUTxOValue = 1_000_000,
      opDisputeDeposit = 5_000_000
    }

-- | Mint the oracle NFT in the test environment and lock initial OracleParams at the oracle validator.
mintTestOracleNFT :: (GYTxGameMonad m, HasCallStack) => User -> m GYAssetClass
mintTestOracleNFT w = asUser w $ do
  -- Find a seed UTxO
  seedGYRef <- someUTxOWithoutRefScript
  let seedPlutus = txOutRefToV3Plutus seedGYRef

  -- Compile the one-shot oracle NFT policy
  let oracleNFTPolicyGY = compileOracleNFTPolicy seedPlutus
  let oracleNFTMPId = mintingPolicyId oracleNFTPolicyGY
  let oracleNFTTN = "" -- empty token name
  let theOracleNFTAC = GYToken oracleNFTMPId oracleNFTTN

  -- Spend seed UTxO
  let spendSeed = mustHaveInput (GYTxIn seedGYRef GYTxInWitnessKey)

  -- Mint oracle NFT
  let mp = GYMintScript @'PlutusV3 oracleNFTPolicyGY
  let gyRedeemer = redeemerFromPlutusData ()
  let mintNFT = mustMint mp gyRedeemer oracleNFTTN 1

  -- Lock oracle NFT + datum at oracle validator address
  lockOutput <-
    txMustLockStateWithInlineDatumAndValue
      oracleValidatorGY
      (initialOracleParamsFor w)
      (valueSingleton theOracleNFTAC 1 <> valueFromLovelace 3_500_000)

  void $ sendSkeleton' $ mconcat [spendSeed, mintNFT, lockOutput]

  gyLogInfo' ("TESTLOG" :: GYLogNamespace) $
    yellowColorString $
      "Oracle NFT minted and locked: " <> show theOracleNFTAC

  return theOracleNFTAC

-- | MALICIOUS: attempt to mint the oracle NFT PLUS an extra token under the one-shot policy.
-- Must fail OracleNFTPolicy N2 (exact-mint: mintValueMinted == theOracleNFT).
maliciousMintOracleNFTWithExtraToken :: (GYTxGameMonad m, HasCallStack) => User -> m GYAssetClass
maliciousMintOracleNFTWithExtraToken w = asUser w $ do
  seedGYRef <- someUTxOWithoutRefScript
  let seedPlutus = txOutRefToV3Plutus seedGYRef
  let oracleNFTPolicyGY = compileOracleNFTPolicy seedPlutus
  let oracleNFTMPId = mintingPolicyId oracleNFTPolicyGY
  let theOracleNFTAC = GYToken oracleNFTMPId ""
  let spendSeed = mustHaveInput (GYTxIn seedGYRef GYTxInWitnessKey)
  let mp = GYMintScript @'PlutusV3 oracleNFTPolicyGY
  let gyRedeemer = redeemerFromPlutusData ()
  -- MALICIOUS: mint the NFT AND an extra token name under the same policy.
  let mintNFT = mustMint mp gyRedeemer "" 1 <> mustMint mp gyRedeemer "EXTRA" 1
  lockOutput <-
    txMustLockStateWithInlineDatumAndValue
      oracleValidatorGY
      (initialOracleParamsFor w)
      (valueSingleton theOracleNFTAC 1 <> valueSingleton (GYToken oracleNFTMPId "EXTRA") 1 <> valueFromLovelace 3_500_000)
  void $ sendSkeleton' $ mconcat [spendSeed, mintNFT, lockOutput]
  return theOracleNFTAC

-- | MALICIOUS: attempt to mint the oracle NFT with a NON-EMPTY token name.
-- Must fail OracleNFTPolicy N2 (theOracleNFT uses the empty token name).
maliciousMintOracleNFTWrongName :: (GYTxGameMonad m, HasCallStack) => User -> m GYAssetClass
maliciousMintOracleNFTWrongName w = asUser w $ do
  seedGYRef <- someUTxOWithoutRefScript
  let seedPlutus = txOutRefToV3Plutus seedGYRef
  let oracleNFTPolicyGY = compileOracleNFTPolicy seedPlutus
  let oracleNFTMPId = mintingPolicyId oracleNFTPolicyGY
  let wrongAC = GYToken oracleNFTMPId "ORACLE"
  let spendSeed = mustHaveInput (GYTxIn seedGYRef GYTxInWitnessKey)
  let mp = GYMintScript @'PlutusV3 oracleNFTPolicyGY
  let gyRedeemer = redeemerFromPlutusData ()
  -- MALICIOUS: non-empty token name.
  let mintNFT = mustMint mp gyRedeemer "ORACLE" 1
  lockOutput <-
    txMustLockStateWithInlineDatumAndValue
      oracleValidatorGY
      (initialOracleParamsFor w)
      (valueSingleton wrongAC 1 <> valueFromLovelace 3_500_000)
  void $ sendSkeleton' $ mconcat [spendSeed, mintNFT, lockOutput]
  return wrongAC

-- | MALICIOUS: an oracle update signed by the ACTOR instead of by the admin.
--
-- This builder exists because 'updateOracleTX' cannot produce the transaction that reaches the
-- validator's @O1@. It reads the current admin out of the oracle datum and adds
-- @mustBeSignedBy adminPkh@, so a non-admin running it builds a transaction it cannot sign — and the
-- submission fails at the required-signer layer, before any script runs. That failure says nothing
-- about whether the oracle validator checks the admin at all.
--
-- Everything here is byte-identical to 'updateOracleTX' except the signatory, so what rejects it is
-- @O1@ and nothing else.
maliciousOracleUpdate ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The actor, who signs; the attack is that this is not the admin.
  User ->
  AdminActionType ->
  m GYTxId
maliciousOracleUpdate ctx actor adminAction = asUser actor $ do
  skeleton <- runReaderT (maliciousOracleUpdateTX (User.userPkh actor) adminAction) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting an oracle update signed by a non-admin (O1)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

maliciousOracleUpdateTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYPubKeyHash ->
  AdminActionType ->
  m (GYTxSkeleton 'PlutusV3)
maliciousOracleUpdateTX attackerPkh adminAction = do
  ovRef <- asks getOracleValidatorRef
  (currentParams, oracleRef, oracleValue) <- queryOracleParams
  let actionPlutus = adminActionToOracleAdminAction adminAction :: OracleAdminAction
  let gyRedeemer = redeemerFromPlutusData (OracleUpdate 0 actionPlutus)
  let newParams = applyAdminAction adminAction currentParams
  let currentDatum = datumFromPlutusData currentParams
  let spendOracle = txMustSpendFromRefScriptWithKnownDatum ovRef oracleRef currentDatum gyRedeemer oracleValidatorGY
  lockOracle <- txMustLockStateWithInlineDatumAndValue oracleValidatorGY newParams oracleValue
  -- MALICIOUS: the attacker signs, the admin does not.
  return $ mconcat [spendOracle, lockOracle, mustBeSignedBy attackerPkh]

profileInteraction :: (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> ProfileActionType -> Maybe GYAddress -> m (GYTxId, GYAssetClass)
profileInteraction txBuildingContext user actionType mrecipient = asUser user $ do
  ((gyTxId, gyAC), balanceDelta) <- withBalance "profileInteraction" user $ do
    let interaction =
          Interaction
            { action = ProfileAction actionType,
              userAddresses = UserAddresses (toList $ User.userAddresses user) (User.userChangeAddress user) Nothing,
              recipient = mrecipient
            }
    (skeleton, mGyAC) <- runReaderT (interactionToTxSkeleton interaction) txBuildingContext
    let gyAC = fromMaybe (error "profileInteraction: ProfileAction returned Nothing for asset class") mGyAC
    (gyTxBody, gyTxId) <- sendSkeleton' skeleton

    -- Log execution units / script budget information
    gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ yellowColorString $ "INTERACTION: \n" <> show interaction
    logTxBudget gyTxBody

    return (gyTxId, gyAC)
  gyLogInfo' ("EXUNITS" :: GYLogNamespace) $
    cyanColorString $
      "USER_BALANCE_CHANGE: " <> show (valueAda balanceDelta) <> " lovelace"
  return (gyTxId, gyAC)

-- | Open or resolve a dispute through the Interaction pipeline.
--
-- Its own runner and not a flag on 'profileInteraction', because that one hardcodes
-- @action = ProfileAction actionType@: a 'DisputeActionType' cannot reach 'interactionToTxSkeleton'
-- through it at all. Returns the dispute's asset class — the newly minted one when opening, the one
-- resolved when resolving — which is what the next call in a test needs.
disputeInteraction :: (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> DisputeActionType -> m (GYTxId, GYAssetClass)
disputeInteraction txBuildingContext user actionType = asUser user $ do
  ((gyTxId, gyAC), balanceDelta) <- withBalance "disputeInteraction" user $ do
    let interaction =
          Interaction
            { action = DisputeAction actionType,
              userAddresses = UserAddresses (toList $ User.userAddresses user) (User.userChangeAddress user) Nothing,
              recipient = Nothing
            }
    (skeleton, mGyAC) <- runReaderT (interactionToTxSkeleton interaction) txBuildingContext
    let gyAC = fromMaybe (error "disputeInteraction: DisputeAction returned Nothing for asset class") mGyAC
    (gyTxBody, gyTxId) <- sendSkeleton' skeleton

    gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ yellowColorString $ "DISPUTE INTERACTION: \n" <> show interaction
    logTxBudget gyTxBody

    return (gyTxId, gyAC)
  gyLogInfo' ("EXUNITS" :: GYLogNamespace) $
    cyanColorString $
      "USER_BALANCE_CHANGE: " <> show (valueAda balanceDelta) <> " lovelace"
  return (gyTxId, gyAC)

-- | Execute a protocol maintenance action (e.g., dust cleanup) through the Interaction pipeline.
protocolInteraction :: (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> ProtocolActionType -> m GYTxId
protocolInteraction txBuildingContext user protocolAction = asUser user $ do
  (gyTxId, balanceDelta) <- withBalance "protocolInteraction" user $ do
    let interaction =
          Interaction
            { action = ProtocolAction protocolAction,
              userAddresses = UserAddresses (toList $ User.userAddresses user) (User.userChangeAddress user) Nothing,
              recipient = Nothing
            }
    (skeleton, _) <- runReaderT (interactionToTxSkeleton interaction) txBuildingContext
    (gyTxBody, gyTxId) <- sendSkeleton' skeleton

    gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ yellowColorString $ "PROTOCOL INTERACTION: \n" <> show interaction
    logTxBudget gyTxBody

    return gyTxId
  gyLogInfo' ("EXUNITS" :: GYLogNamespace) $
    cyanColorString $
      "USER_BALANCE_CHANGE: " <> show (valueAda balanceDelta) <> " lovelace"
  return gyTxId

-- | Execute an admin action (oracle update) through the Interaction pipeline.
adminInteraction :: (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> AdminActionType -> m GYTxId
adminInteraction txBuildingContext user adminAction = asUser user $ do
  (gyTxId, balanceDelta) <- withBalance "adminInteraction" user $ do
    let interaction =
          Interaction
            { action = AdminAction adminAction,
              userAddresses = UserAddresses (toList $ User.userAddresses user) (User.userChangeAddress user) Nothing,
              recipient = Nothing
            }
    (skeleton, _) <- runReaderT (interactionToTxSkeleton interaction) txBuildingContext
    (gyTxBody, gyTxId) <- sendSkeleton' skeleton

    gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ yellowColorString $ "ADMIN INTERACTION: \n" <> show interaction
    logTxBudget gyTxBody

    return gyTxId
  gyLogInfo' ("EXUNITS" :: GYLogNamespace) $
    cyanColorString $
      "USER_BALANCE_CHANGE: " <> show (valueAda balanceDelta) <> " lovelace"
  return gyTxId

-- | Log transaction budget information including fee and script execution units
logTxBudget :: (GYTxQueryMonad m) => GYTxBody -> m ()
logTxBudget txBody = do
  let fee = txBodyFee txBody
  gyLogInfo' ("EXUNITS" :: GYLogNamespace) $
    cyanColorString $
      "TX BUDGET:\n"
        <> "  Fee: "
        <> show fee
        <> " lovelace\n"
        <> "  TxBody: "
        <> show txBody

------------------------------------------------------------------------------------------------

-- * Dust / Cleanup Helpers

------------------------------------------------------------------------------------------------

-- | Send a dust UTxO (ADA only, no datum) to a validator address to simulate griefing.
sendDustToValidator :: (GYTxGameMonad m, HasCallStack) => User -> GYScript 'PlutusV3 -> m ()
sendDustToValidator user validator = asUser user $ do
  validatorAddr <- scriptAddress validator
  let dustSkeleton =
        mustHaveOutput
          GYTxOut
            { gyTxOutAddress = validatorAddr,
              gyTxOutDatum = Nothing,
              gyTxOutValue = valueFromLovelace 2_000_000,
              gyTxOutRefS = Nothing
            }
  void $ sendSkeleton' dustSkeleton
  gyLogInfo' ("TESTLOG" :: GYLogNamespace) $
    yellowColorString $
      "Sent dust UTxO (2 ADA, no datum) to validator: " <> show (scriptHash validator)

-- | Lock a UTxO at a validator address carrying a datum that PARSES as that validator's state, but
-- no protocol token.
--
-- That combination is what makes it interesting: 'Palmares.TxBuilding.Lookups.getDustUTxOs' selects
-- on the absence of a protocol-policy token, so the cleanup sweep picks this UTxO up as dust and
-- builds a @Cleanup@ spend for it — and then the validator must refuse, because its datum parses.
-- Dust that merely lacks a datum never reaches that branch.
lockParsingDatumAt :: (GYTxGameMonad m, HasCallStack, ToData a) => User -> GYScript 'PlutusV3 -> a -> m ()
lockParsingDatumAt user validator datum = asUser user $ do
  skeleton <- txMustLockStateWithInlineDatumAndValue validator datum (valueFromLovelace 2_000_000)
  void $ sendSkeleton' skeleton
  gyLogInfo' ("TESTLOG" :: GYLogNamespace) $
    yellowColorString $
      "Locked a PARSING datum (no protocol token) at validator: " <> show (scriptHash validator)

-- | Send a plain, datum-less ADA UTxO to any address.
--
-- The general sibling of 'sendDustToValidator', and the claim tests cannot be written without it: a
-- script credential proves control __by spending something__, so something has to be there first.
-- 'Palmares.TxBuilding.Operations.claimProofSkeleton' refuses with @ScriptCredentialHasNoUtxo@ when
-- it is not.
sendAdaToAddress :: (GYTxGameMonad m, HasCallStack) => User -> GYAddress -> Integer -> m ()
sendAdaToAddress user addr lovelace = asUser user $ do
  skeleton <- txMustPayValueToAddress addr (valueFromLovelace lovelace)
  void $ sendSkeleton' skeleton
  gyLogInfo' ("TESTLOG" :: GYLogNamespace) $
    yellowColorString $
      "Sent " <> show lovelace <> " lovelace to " <> show addr

------------------------------------------------------------------------------------------------

-- * Malicious builders for the claim, the attestation and the dispute
--
-- Every builder below exists for one reason: the production path cannot produce the transaction
-- that reaches the on-chain check we want to assert. 'Palmares.TxBuilding.Operations' refuses these
-- off chain — with a 400, a missing required signer, or an unbuildable output — and a @mustFail@ on
-- that refusal says nothing about whether the validator checks anything at all. That is the mistake
-- 'UnitTests.Oracle' documents for @O1@; these are the same remedy for @Mp3@, @Mp2@, @Ml@, @Mf@,
-- @A3@, @D1@ and @D3@.

------------------------------------------------------------------------------------------------

-- | MALICIOUS: mint a profile that CLAIMS a credential while proving nothing.
--
-- 'claimProofSkeleton' is what makes the claim real: a key credential gets @mustBeSignedBy@, a
-- script credential gets a spend of one of its own UTxOs. Neither can be omitted through the API, so
-- @Mp3@ is unreachable from it — and @Mp3@ is the whole identity rule.
--
-- @mProofRef@ is the input the attacker OFFERS as proof, spent with a plain key witness:
--
--   * 'Nothing' — no proof at all. The redeemer names a credential and the transaction carries
--     neither its signature nor any input it governs.
--   * @'Just' ref@ — a spend the attacker believes proves control. This is how the fixed
--     staking-credential hole is asserted: a UTxO whose __staking__ part is the claimed script and
--     whose payment part is the attacker's own key. The ledger authenticates the payment part and
--     nothing else, so this must be refused.
maliciousClaimWithoutControl ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The attacker, who pays and signs.
  User ->
  ProfileType ->
  -- | The credential the redeemer claims.
  V3.Credential ->
  MetadataFields ->
  -- | The input offered as proof of control, if any.
  Maybe GYTxOutRef ->
  m (GYTxId, GYAssetClass)
maliciousClaimWithoutControl ctx attacker kind credential metadata mProofRef = asUser attacker $ do
  (skeleton, gyProfileRefAC) <- runReaderT (maliciousClaimTX kind credential metadata mProofRef) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) $
    "Attempting a profile claim with no proof of control over " <> show credential <> " (Mp3)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return (gyTxId, gyProfileRefAC)

-- | Byte-identical to 'Palmares.TxBuilding.Operations.claimProfileTX' except that the proof is the
-- caller's choice instead of 'claimProofSkeleton''s, so what rejects it is @Mp3@ and nothing else.
maliciousClaimTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  ProfileType ->
  V3.Credential ->
  MetadataFields ->
  Maybe GYTxOutRef ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
maliciousClaimTX kind credential metadata mProofRef = do
  ctx <- ask
  let mpGY = getMintingPolicyFromCtx ctx
      mpRef = getMintingPolicyRef ctx
      onchainKind = profileTypeToOnchainProfileKind kind
  (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionProfile
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
      seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef
      profileOutputIdx = 0 :: Integer
      -- MALICIOUS: a plain key-witnessed spend, or nothing at all. No required signer and no script
      -- witness, which is precisely what `claimProofSkeleton` would have added.
      claimProof = maybe mempty (\r -> mustHaveInput (GYTxIn r GYTxInWitnessKey)) mProofRef

  let gyRedeemer =
        redeemerFromPlutusData (MintProfile seedTxOutRefPlutus onchainKind (Just credential) metadata profileOutputIdx)
  (gyProfileRefAC, _gyProfileUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingProfileNFTs <- txMustMintCIP68UserAndRef mpRef mpGY gyRedeemer gyProfileRefAC

  let profileInfo =
        OnchainTypes.OnchainProfile
          { OnchainTypes.profileId = assetClassToPlutus gyProfileRefAC,
            OnchainTypes.profileKind = onchainKind,
            OnchainTypes.profileCredential = Just credential,
            OnchainTypes.protocolParams = getProtocolParamsFromCtx ctx
          }
  let profileDatum = mkCIP68Datum profileInfo metadata []
  isLockingProfileState <-
    txMustLockStateWithInlineDatumAndValue
      profilesValidatorGY
      profileDatum
      (valueSingleton gyProfileRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO,
          claimProof,
          isValidForSafeEra,
          oracleRefSkeleton,
          isMintingProfileNFTs,
          isLockingProfileState,
          feeSkeleton
        ],
      gyProfileRefAC
    )

-- | MALICIOUS: a legitimate profile mint with ONE extra token minted under the protocol policy.
--
-- Built by taking the production skeleton and appending a mint, which works because the skeleton's
-- 'Semigroup' merges the token maps per minting script and keeps the __left__ redeemer — so the
-- policy still runs with the redeemer 'claimProfileTX' built, and sees a mint that does not match
-- it. @Mp2@ is what must notice.
maliciousMintProfileWithExtraToken ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  User ->
  ProfileActionType ->
  -- | The extra token name minted alongside the CIP-68 pair.
  GYTokenName ->
  m GYTxId
maliciousMintProfileWithExtraToken ctx attacker actionType extraTN = asUser attacker $ do
  skeleton <- profileSkeletonFor ctx attacker actionType
  let attack = mustMint (protocolMintScript ctx) discardedRedeemer extraTN 1
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting a profile mint with an extra token (Mp2)..."
  (gyTxBody, gyTxId) <- sendSkeleton' (skeleton <> attack)
  logTxBudget gyTxBody
  return gyTxId

-- | MALICIOUS: a legitimate profile mint that also BURNS an existing profile's user token.
--
-- @Mp2@ forbids burns as well as extra mints, and the burn half is the one that matters on a chain
-- where nothing is supposed to burn: a mint transaction that could also destroy a user token could
-- destroy somebody's authority instrument while minting its own.
--
-- The token spent is passed in and spent EXPLICITLY rather than left to the balancer, so the
-- transaction is guaranteed to balance and the only thing that can refuse it is the policy.
maliciousMintProfileWithBurn ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  User ->
  ProfileActionType ->
  -- | The profile whose USER token is burned. Must be held by the attacker.
  GYAssetClass ->
  m GYTxId
maliciousMintProfileWithBurn ctx attacker actionType burnProfileRefAC = asUser attacker $ do
  skeleton <- profileSkeletonFor ctx attacker actionType
  burnUserAC <- gyDeriveUserFromRefAC burnProfileRefAC
  burnTN <- tnFromGYAssetClass burnUserAC
  spendsBurned <- txMustSpendFromAddress burnUserAC (toList $ User.userAddresses attacker) GYTxInWitnessKey
  let attack = spendsBurned <> mustMint (protocolMintScript ctx) discardedRedeemer burnTN (negate 1)
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting a profile mint that also burns a user token (Mp2)..."
  (gyTxBody, gyTxId) <- sendSkeleton' (skeleton <> attack)
  logTxBudget gyTxBody
  return gyTxId

-- | The production profile skeleton, for the two builders above to attach an attack to.
profileSkeletonFor ::
  (HasCallStack, GYTxUserQueryMonad m) =>
  DeployedScriptsContext ->
  User ->
  ProfileActionType ->
  m (GYTxSkeleton 'PlutusV3)
profileSkeletonFor ctx user actionType = do
  let interaction =
        Interaction
          { action = ProfileAction actionType,
            userAddresses = UserAddresses (toList $ User.userAddresses user) (User.userChangeAddress user) Nothing,
            recipient = Nothing
          }
  fst <$> runReaderT (interactionToTxSkeleton interaction) ctx

-- | The protocol minting policy as the production path references it. The key must be identical for
-- an appended mint to merge into the same entry rather than add a second script.
protocolMintScript :: DeployedScriptsContext -> GYBuildScript 'PlutusV3
protocolMintScript ctx = GYMintReference @'PlutusV3 (getMintingPolicyRef ctx) (getMintingPolicyFromCtx ctx)

-- | A redeemer that is DISCARDED by the skeleton merge (the left one wins per minting script).
-- Named so that no reader has to work out why a unit redeemer is acceptable here.
discardedRedeemer :: GYRedeemer
discardedRedeemer = redeemerFromPlutusData ()

-- | MALICIOUS: issue an attestation with the recorded date moved off the chain tip, or paid for with
-- a user token that is not the named issuer's.
--
-- Both knobs are unreachable through the API by construction. The date is derived from
-- 'slotOfCurrentBlock' (inherited fix #4), so a client cannot back-date at all; and the issuer's
-- user NFT is looked up from the caller's own addresses, so naming someone else's issuer profile is
-- a @ProfileNotFound@ long before @Mf@. @Ml@ and @Mf@ are therefore only assertable from here.
maliciousIssueAttestation ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  User ->
  -- | Subject profile id
  GYAssetClass ->
  -- | Issuer profile id, as NAMED in the redeemer and the datum
  GYAssetClass ->
  AttestationType ->
  MetadataFields ->
  -- | Milliseconds to subtract from the chain tip for the recorded date. 0 is honest.
  Integer ->
  -- | The profile whose user token actually pays. Honest when it equals the named issuer.
  GYAssetClass ->
  m (GYTxId, GYAssetClass)
maliciousIssueAttestation ctx attacker subjectId issuerId kind metadata backdateMs spendProfileId = asUser attacker $ do
  let ownAddrs = toList $ User.userAddresses attacker
  (skeleton, gyAttestationRefAC) <-
    runReaderT (maliciousIssueAttestationTX subjectId issuerId kind metadata backdateMs spendProfileId ownAddrs) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) $
    "Attempting an attestation back-dated by " <> show backdateMs <> "ms, paid by " <> show spendProfileId <> "..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return (gyTxId, gyAttestationRefAC)

-- | Byte-identical to 'Palmares.TxBuilding.Operations.issueAttestationTX' except for the recorded
-- date and which user token pays, so what rejects it is @Ml@ or @Mf@ and nothing else.
--
-- The date goes into the redeemer AND the datum, because @Mk@ compares the whole datum: changing one
-- and not the other would fail at @Mk@ and say nothing about the date check.
maliciousIssueAttestationTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  GYAssetClass ->
  AttestationType ->
  MetadataFields ->
  Integer ->
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
maliciousIssueAttestationTX subjectId issuerId kind metadata backdateMs spendProfileId ownAddrs = do
  mpGY <- asks getMintingPolicyFromCtx
  mpRef <- asks getMintingPolicyRef
  (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionAttestation
  let minLv = OnchainTypes.opMinUTxOValue oracleParams
      onchainKind = attestationTypeToOnchainAttestationKind kind

  now <- slotOfCurrentBlock
  tipDate <- pPOSIXTimeFromGYSlot now
  -- MALICIOUS: not the tip.
  let V3.POSIXTime tipMs = tipDate
      attestationDate = V3.POSIXTime (tipMs - backdateMs)

  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
      seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef
      attestationOutputIdx = 0 :: Integer

  -- MALICIOUS: whichever profile's user token the attacker actually holds.
  spendsUserNFT <- spendUserNFTForProfile spendProfileId ownAddrs

  let gyRedeemer =
        redeemerFromPlutusData
          ( NewAttestation
              seedTxOutRefPlutus
              metadata
              []
              (assetClassToPlutus subjectId)
              (assetClassToPlutus issuerId)
              onchainKind
              attestationDate
              Nothing
              attestationOutputIdx
          )
  (gyAttestationRefAC, _) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingAttestationNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyAttestationRefAC

  let attestationInfo =
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus gyAttestationRefAC,
            OnchainTypes.attestationSubject = assetClassToPlutus subjectId,
            OnchainTypes.attestationIssuer = assetClassToPlutus issuerId,
            OnchainTypes.attestationKind = onchainKind,
            OnchainTypes.attestationDate = attestationDate,
            OnchainTypes.attestationPeriod = Nothing,
            OnchainTypes.attestationIsAccepted = False
          }
  let attestationDatum = mkCIP68Datum attestationInfo metadata []
  isLockingAttestation <-
    txMustLockStateWithInlineDatumAndValue
      attestationsValidatorGY
      attestationDatum
      (valueSingleton gyAttestationRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO,
          spendsUserNFT,
          isValidForSafeEra,
          oracleRefSkeleton,
          isMintingAttestationNFT,
          isLockingAttestation,
          feeSkeleton
        ],
      gyAttestationRefAC
    )

-- | MALICIOUS: accept an attestation that is already accepted.
--
-- 'Palmares.TxBuilding.Operations.acceptAttestationTX' throws @AttestationAlreadyAccepted@ before it
-- builds anything, so @A3@ cannot be reached through the API. Dropping that one guard is the whole
-- difference here — and the transaction it produces is otherwise a valid acceptance, writing a datum
-- identical to the one already on chain, which is exactly why only @A3@ can refuse it.
maliciousDoubleAccept ::
  (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> GYAssetClass -> m GYTxId
maliciousDoubleAccept ctx subject attestationAC = asUser subject $ do
  let ownAddrs = toList $ User.userAddresses subject
  skeleton <- runReaderT (maliciousAcceptTX attestationAC ownAddrs) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting to accept an already-accepted attestation (A3)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

maliciousAcceptTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
maliciousAcceptTX gyAttestationAC ownAddrs = do
  avRef <- asks getAttestationsValidatorRef
  (oracleRefSkeleton, isValidForSafeEra) <- getOracleAndValiditySkeleton
  (attestationDatum, attestationValue) <- getAttestationDatumAndValue gyAttestationAC

  gySubjectProfileRefAC <- assetClassFromPlutus' (OnchainTypes.attestationSubject (extra attestationDatum))
  gySubjectUserAC <- gyDeriveUserFromRefAC gySubjectProfileRefAC
  spendsSubjectUserNFT <- txMustSpendFromAddress gySubjectUserAC ownAddrs GYTxInWitnessKey

  -- MALICIOUS: no `AttestationAlreadyAccepted` guard.
  let updatedAttestationDatum =
        attestationDatum {extra = (extra attestationDatum) {OnchainTypes.attestationIsAccepted = True}}
  let avRedeemer = redeemerFromPlutusData (AcceptAttestation 0)
  spendsAttestation <- txMustSpendStateFromRefScriptWithRedeemer avRef gyAttestationAC avRedeemer attestationsValidatorGY

  gyAttestationValue <- valueFromPlutus' attestationValue
  isLockingUpdatedAttestation <-
    txMustLockStateWithInlineDatumAndValue attestationsValidatorGY updatedAttestationDatum gyAttestationValue

  return $
    mconcat
      [ spendsSubjectUserNFT,
        spendsAttestation,
        isValidForSafeEra,
        oracleRefSkeleton,
        isLockingUpdatedAttestation
      ]

-- | MALICIOUS: resolve a dispute as the ACTOR rather than as the oracle admin, and without the
-- off-chain already-resolved guard.
--
-- One builder for @D1@ and @D3@ because both are unreachable through
-- 'Palmares.TxBuilding.Operations.resolveDisputeTX' for different reasons: it demands the datum's
-- admin as a signer (so a non-admin builds a transaction nobody can sign, failing at the
-- required-signer layer with no script run) and it throws @DisputeAlreadyResolved@ before building
-- (so @D3@ never runs). Pass a non-admin actor for @D1@; pass the admin and an already-resolved
-- dispute for @D3@.
--
-- __The locked value is re-locked UNCHANGED and the deposit is paid out of the attacker's own
-- funds.__ The production builder subtracts the deposit from the dispute UTxO, which for a
-- second resolution would mean an output of 1 ADA minus a 5 ADA deposit — a negative output that
-- fails to build, so the test would never reach @D3@. Paying it instead keeps the transaction
-- buildable, and @D3@ is the first conjunct in the validator, so it is what rejects it.
maliciousResolveDispute ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The actor, who signs; for @D1@ the attack is that this is not the admin.
  User ->
  GYAssetClass ->
  DisputeVerdict ->
  m GYTxId
maliciousResolveDispute ctx actor disputeAC verdict = asUser actor $ do
  skeleton <- runReaderT (maliciousResolveDisputeTX (User.userPkh actor) disputeAC verdict) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting a dispute resolution signed by the actor (D1/D3)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

maliciousResolveDisputeTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYPubKeyHash ->
  GYAssetClass ->
  DisputeVerdict ->
  m (GYTxSkeleton 'PlutusV3)
maliciousResolveDisputeTX actorPkh gyDisputeAC verdict = do
  dvRef <- asks getDisputesValidatorRef
  (disputeDatum, plutusDisputeValue) <- getDisputeDatumAndValue gyDisputeAC
  let dispute = extra disputeDatum
      onchainVerdict = disputeVerdictToOnchainVerdict verdict
  (_oracleParams, oracleRef, _oracleValue) <- queryOracleParams

  let gyRedeemer = redeemerFromPlutusData (DisputesValidator.ResolveDispute onchainVerdict 0)
  spendsDispute <- txMustSpendStateFromRefScriptWithRedeemer dvRef gyDisputeAC gyRedeemer disputesValidatorGY

  gyDisputeValue <- valueFromPlutus' plutusDisputeValue
  gyDepositTo <- addressFromPlutus' (OnchainTypes.disputeDepositTo dispute)
  let depositValue = valueFromLovelace (OnchainTypes.disputeDeposit dispute)
      resolvedDatum = disputeDatum {extra = OnchainTypes.resolveDispute onchainVerdict dispute}

  isLockingResolvedDispute <-
    txMustLockStateWithInlineDatumAndValue disputesValidatorGY resolvedDatum gyDisputeValue
  isReturningDeposit <- txMustPayValueToAddress gyDepositTo depositValue

  -- MALICIOUS: the actor signs, the oracle admin need not.
  return $
    mconcat
      [ spendsDispute,
        mustHaveRefInput oracleRef,
        isLockingResolvedDispute,
        isReturningDeposit,
        mustBeSignedBy actorPkh
      ]
