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
-- do not exist here, and the double-accept attack they existed to test is gone with them. What
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
    adminRotateInteraction,

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
    maliciousAcceptWhilePaused,
    maliciousDoubleAccept,
    maliciousUpdateProfile,
    maliciousResolveDispute,
    maliciousResolveTwoDisputes,
    maliciousCleanupState,
  )
where

import Control.Monad (void)
import Control.Monad.Reader
import Data.Foldable.Extra
import Data.Maybe (fromMaybe)
import GHC.Stack
import GeniusYield.Examples.Limbo (limboValidatorV2)
import GeniusYield.Test.Clb (sendSkeleton')
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder hiding (userAddresses)
import GeniusYield.TxBuilder.User qualified as User
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types (AttestationType, DisputeVerdict)
import Palmares.Onchain.CIP68 (CIP68Datum (..), ImageURI, MetadataFields (..), getMetadataFields, mkCIP68Datum, updateCIP68DatumMetadata)
import Palmares.Onchain.Protocol.Types (OracleAdminAction, OracleParams (..))
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer (AcceptAttestation))
import Palmares.Onchain.Validators.DisputesValidator qualified as DisputesValidator (DisputesRedeemer (ResolveDispute))
import Palmares.Onchain.Validators.MintingPolicy (MintingRedeemer (NewAttestation))
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile))
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Conversions
  ( attestationTypeToOnchainAttestationKind,
    disputeVerdictToOnchainVerdict,
  )
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue, getDisputeDatumAndValue, getProfileStateDatumAndValue, queryOracleParams)
import Palmares.TxBuilding.Operations
  ( adminActionToOracleAdminAction,
    applyAdminAction,
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

-- | Deploy one reference script the way production does: to the always-fail limbo address.
--
-- It used to land at a wallet's own address, which is what @OF-08@ fixed off chain — and keeping
-- the emulator on the old shape would mean no test ever exercises a reference input read out of a
-- SCRIPT address with an inline unit datum. That it is read-only and needs no redeemer is a ledger
-- rule worth having a test behind, and every runner below now depends on it.
deployReferenceScriptRun :: (GYTxGameMonad m, HasCallStack) => GYScript PlutusV3 -> User -> m (GYScriptHash, GYTxOutRef)
deployReferenceScriptRun validator fromWallet = asUser fromWallet $ do
  limboAddr <- scriptAddress limboValidatorV2
  ref <- addRefScript limboAddr (validatorToScript validator)
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
  (pVhash, refProfilesValidator) <- deployReferenceScriptRun profilesValidatorGY w
  (aVhash, refAttestationsValidator) <- deployReferenceScriptRun attestationsValidatorGY w
  (dVhash, refDisputesValidator) <- deployReferenceScriptRun disputesValidatorGY w
  (ovHash, refOracleValidator) <- deployReferenceScriptRun oracleValidatorGY w

  -- Step 2: Mint oracle NFT and lock initial OracleParams at oracle validator
  oracleNFTAC <- mintTestOracleNFT w

  -- Step 3: Compile minting policy with the oracle NFT asset class and deploy
  let mpGY = compileMintingPolicy (assetClassToPlutus oracleNFTAC)
  (mphash, refMintingPolicy) <- deployReferenceScriptRun mpGY w

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
-- 'opAdmin' must be a wallet that can actually sign, because the oracle validator checks the
-- signature on chain — a placeholder hash here would make every admin test unfailable for the wrong
-- reason. The other four are the deployment defaults: unpaused, no fees (the preprod configuration),
-- 1 ADA minimum for protocol state, 5 ADA to open a dispute.
initialOracleParamsFor :: User -> OracleParams
initialOracleParamsFor w =
  OracleParams
    { opAdmin = V3.PubKeyCredential (userPlutusPkh w),
      opArbiter = V3.PubKeyCredential (userPlutusPkh w),
      opPaused = False,
      opFeeConfig = Nothing,
      opMinUTxOValue = 1_000_000,
      opDisputeDeposit = 5_000_000,
      opDisputeTimeoutMs = 2_592_000_000
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
            { action = AdminAction adminAction Nothing,
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
-- That combination is what makes it interesting, and the reason changed under this comment: the old
-- 'Palmares.TxBuilding.Lookups.getDustUTxOs' selected on the ABSENCE of a protocol-policy token, so
-- it offered this UTxO and the validator then refused it — which is the all-or-nothing brick the
-- selector fix closed. The selector now mirrors @isUnbackedDatum@: this UTxO's datum parses but the
-- NFT it names is not in its own value, so the validator ALLOWS the sweep and the selector offers
-- it. Dust that merely lacks a datum is allowed by the same arm, by its first case.
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
-- off chain — with a 400, a missing required signer, an unbuildable output, or an off-chain filter
-- that never offers the UTxO — and a @mustFail@ on that refusal says nothing about whether the
-- validator checks anything at all. That is the mistake 'UnitTests.Oracle' documents for @O1@; these
-- are the same remedy for @Mc3@, @Mp2@, @Ml@, @Mf@, @A3@, @D1@, @D3@, @P6@ and the three @Cleanup@
-- codes @P7@/@A4@/@D8@. (Those three were written here as @P0@/@A0@/@D0@, which are the NO-DATUM
-- codes on the other redeemers; under @Cleanup@ an absent datum reaches no trace code at all.)

------------------------------------------------------------------------------------------------

-- | MALICIOUS: mint a credential-claim record while proving nothing.
--
-- 'claimProofSkeleton' is what makes the claim real: a key credential gets @mustBeSignedBy@, a
-- script credential gets a spend of one of its own UTxOs. Neither can be omitted through the API, so
-- @Mc3@ is unreachable from it — and @Mc3@ is the whole identity rule.
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
  -- | The attacker, who pays and signs. Holds the profile's user token, so @Mf@ passes.
  User ->
  -- | The profile that is binding itself — it has to exist first, since ADR 0003 made the binding
  -- its own record rather than part of the profile mint.
  GYAssetClass ->
  -- | The credential the record claims, under the role it claims it as — ADR 0006.
  OnchainTypes.ClaimedCredential ->
  MetadataFields ->
  -- | The input offered as proof of control, if any.
  Maybe GYTxOutRef ->
  m (GYTxId, GYAssetClass)
maliciousClaimWithoutControl ctx attacker profileRefAC credential metadata mProofRef = asUser attacker $ do
  let ownAddrs = toList $ User.userAddresses attacker
  (skeleton, gyRecordAC) <- runReaderT (maliciousClaimTX profileRefAC credential metadata mProofRef ownAddrs) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) $
    "Attempting a credential binding with no proof of control over " <> show credential <> " (Mc3)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return (gyTxId, gyRecordAC)

-- | Byte-identical to 'Palmares.TxBuilding.Operations.credentialAttestationTX' except that the proof
-- is the caller's choice instead of 'claimProofSkeleton''s, so what rejects it is @Mc3@ and nothing
-- else.
--
-- It still spends the profile's user NFT, which is what keeps @Mf@ satisfied and therefore keeps
-- @Mc3@ the only rule left to say no. Before ADR 0003 this builder mounted the same attack on the
-- profile MINT against @Mp3@; the attack is unchanged, the record it lands in is not.
maliciousClaimTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  OnchainTypes.ClaimedCredential ->
  MetadataFields ->
  Maybe GYTxOutRef ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
maliciousClaimTX profileRefAC credential metadata mProofRef ownAddrs = do
  ctx <- ask
  let mpGY = getMintingPolicyFromCtx ctx
      mpRef = getMintingPolicyRef ctx
  (oracleRefSkeleton, oracleParams, feeSkeleton, isInvalidBeforeNow) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionAttestation
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  gyProfileUserAC <- gyDeriveUserFromRefAC profileRefAC
  spendsProfileUserNFT <- txMustSpendFromAddress gyProfileUserAC ownAddrs GYTxInWitnessKey

  now <- slotOfCurrentBlock
  recordedAt <- pPOSIXTimeFromGYSlot now

  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
      seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef
      attestationOutputIdx = 0 :: Integer
      plutusProfileId = assetClassToPlutus profileRefAC
      -- MALICIOUS: a plain key-witnessed spend, or nothing at all. No required signer and no script
      -- witness, which is precisely what `claimProofSkeleton` would have added.
      claimProof = maybe mempty (\r -> mustHaveInput (GYTxIn r GYTxInWitnessKey)) mProofRef

  let gyRedeemer =
        redeemerFromPlutusData
          ( NewAttestation
              seedTxOutRefPlutus
              metadata
              []
              plutusProfileId
              plutusProfileId
              OnchainTypes.CredentialClaim
              recordedAt
              Nothing
              (Just credential)
              attestationOutputIdx
          )
  (gyRecordAC, _) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingRecord <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyRecordAC

  let recordInfo =
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus gyRecordAC,
            OnchainTypes.attestationSubject = plutusProfileId,
            OnchainTypes.attestationIssuer = plutusProfileId,
            OnchainTypes.attestationKind = OnchainTypes.CredentialClaim,
            OnchainTypes.attestationDate = recordedAt,
            OnchainTypes.attestationPeriod = Nothing,
            OnchainTypes.attestationIsAccepted = False,
            OnchainTypes.attestationOracleToken = OnchainTypes.oracleToken (getProtocolParamsFromCtx ctx),
            OnchainTypes.attestationCredential = Just credential
          }
  let recordDatum = mkCIP68Datum recordInfo metadata []
  isLockingRecord <-
    txMustLockStateWithInlineDatumAndValue
      attestationsValidatorGY
      recordDatum
      (valueSingleton gyRecordAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO,
          spendsProfileUserNFT,
          claimProof,
          isInvalidBeforeNow,
          oracleRefSkeleton,
          isMintingRecord,
          isLockingRecord,
          feeSkeleton
        ],
      gyRecordAC
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
  -- The REAL oracle token, deliberately: this builder is malicious only in the ways each test
  -- names, and a fake token here would fail every one of them at `Mk` for the wrong reason.
  attestationProtocolParams <- asks getProtocolParamsFromCtx
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
            OnchainTypes.attestationIsAccepted = False,
            OnchainTypes.attestationOracleToken = OnchainTypes.oracleToken attestationProtocolParams,
            OnchainTypes.attestationCredential = Nothing
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

-- | MALICIOUS: accept an attestation while the protocol is paused — the only way to reach @A7@.
--
-- The same builder as 'maliciousDoubleAccept'; a separate wrapper only so the log names the rule
-- under test, which is how an operator reading a failed emulator run tells the two apart.
maliciousAcceptWhilePaused ::
  (GYTxGameMonad m, HasCallStack) => DeployedScriptsContext -> User -> GYAssetClass -> m GYTxId
maliciousAcceptWhilePaused ctx subject attestationAC = asUser subject $ do
  let ownAddrs = toList $ User.userAddresses subject
  skeleton <- runReaderT (maliciousAcceptTX attestationAC ownAddrs) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting an acceptance with no off-chain pause guard (A7)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

-- | Byte-identical to 'Palmares.TxBuilding.Operations.acceptAttestationTX' except for two guards it
-- drops, both of which are off-chain only.
--
-- __The oracle reference input is still attached__, by hand, exactly as 'maliciousUpdateProfileTX'
-- does it and for the same reason: dropping the pause CHECK while keeping the reference input is
-- what leaves @A7@ as the only thing that can refuse a paused acceptance. Without it the failure
-- would be @readOracleParams@ raising because no input carries the oracle token, and the test would
-- assert the wrong guard — which is also the fail-closed property @A7@ relies on, since an attacker
-- cannot reach the acceptance path by simply leaving the oracle out.
maliciousAcceptTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
maliciousAcceptTX gyAttestationAC ownAddrs = do
  avRef <- asks getAttestationsValidatorRef
  -- MALICIOUS: the reference input without the pause check that comes with it.
  (_oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  now <- slotOfCurrentBlock
  let oracleRefSkeleton = mustHaveRefInput oracleRef
      isValidForSafeEra = txIsValidForSafeEra now
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

-- | MALICIOUS: update a profile without the off-chain pause guard — the only way to reach @P6@.
--
-- 'Palmares.TxBuilding.Operations.updateProfileTX' goes through @getOracleRefInputSkeleton@, which
-- throws @ProtocolPaused@ at skeleton-BUILD time, so through the API a paused update dies before any
-- script runs. That refusal is what @UnitTests.Attestation@'s @pauseStopsEverything@ asserts with a
-- bare 'mustFail', and
-- it would keep passing with @P6@ deleted — the mistake 'UnitTests.Oracle' documents for @O1@.
--
-- __The oracle reference input is still attached__, and that is the whole difference from the
-- production builder: dropping the pause CHECK while keeping the reference input is what leaves @P6@
-- as the only thing that can refuse the transaction. Without the reference input the failure would be
-- @K1@ (no input carries the oracle token) and the test would assert the wrong guard.
maliciousUpdateProfile ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The profile's owner, who holds its user token. The attack is the pause, not the authority.
  User ->
  GYAssetClass ->
  -- | The new image URI, which is the field an update always rewrites.
  ImageURI ->
  m GYTxId
maliciousUpdateProfile ctx owner profileRefAC newImageURI = asUser owner $ do
  let ownAddrs = toList $ User.userAddresses owner
  skeleton <- runReaderT (maliciousUpdateProfileTX profileRefAC newImageURI ownAddrs) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting a profile update with no off-chain pause guard (P6)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

-- | Byte-identical to 'Palmares.TxBuilding.Operations.updateProfileTX' except that the oracle is
-- attached as a bare reference input instead of through @getOracleAndValiditySkeleton@, so what
-- rejects it is @P6@ and nothing else.
maliciousUpdateProfileTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  ImageURI ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
maliciousUpdateProfileTX gyProfileRefAC newImageURI ownAddrs = do
  pvRef <- asks getProfilesValidatorRef
  -- MALICIOUS: the reference input without the pause check that comes with it.
  (_oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  now <- slotOfCurrentBlock
  (plutusProfileDatum, plutusProfileValue) <- getProfileStateDatumAndValue gyProfileRefAC

  let profileOutputIdx = 0 :: Integer
      -- The production merge: name is immutable, description is kept, the image is replaced.
      mergedFields = (getMetadataFields plutusProfileDatum) {metadataImageURI = newImageURI}
      gyRedeemer = redeemerFromPlutusData (UpdateProfile mergedFields profileOutputIdx)
      newCip68Datum = updateCIP68DatumMetadata mergedFields plutusProfileDatum

  spendsProfileRefNFT <- txMustSpendStateFromRefScriptWithRedeemer pvRef gyProfileRefAC gyRedeemer profilesValidatorGY
  spendsProfileUserNFT <- spendUserNFTForProfile gyProfileRefAC ownAddrs
  gyProfileValue <- valueFromPlutus' plutusProfileValue
  isLockingUpdatedProfileState <- txMustLockStateWithInlineDatumAndValue profilesValidatorGY newCip68Datum gyProfileValue

  return $
    mconcat
      [ spendsProfileUserNFT,
        spendsProfileRefNFT,
        txIsValidForSafeEra now,
        mustHaveRefInput oracleRef, -- Reference input: oracle UTxO, which P6 reads opPaused from
        isLockingUpdatedProfileState -- Output 0: Updated profile state
      ]

-- | MALICIOUS: spend REAL protocol state with the permissionless @Cleanup@ redeemer.
--
-- The dust sweep cannot produce this transaction: 'Palmares.TxBuilding.Lookups.getDustUTxOs' never
-- offers a UTxO whose own value backs the state NFT its datum names, so a state UTxO is never
-- selected. That off-chain filter is also why the inherited suite's five cleanup cases all passed
-- with @Cleanup@ effectively unchecked — none of them could reach the on-chain arm with real state in
-- front of it.
--
-- What it asserts is the dangerous half of the value-backed guard: a datum the UTxO's own NFT backs
-- is state, and @P7@/@A4@/@D8@ must refuse the sweep. Each validator looks up its own NFT through its
-- own datum field, and those fields are all 'PlutusLedgerApi.V1.Value.AssetClass' — @disputeTarget@
-- in place of @disputeId@ type-checks — so the three cases are three different checks, not one
-- repeated.
--
-- The NFT and the min-ADA would land in the actor's change output, which is exactly the theft the
-- refusal prevents.
maliciousCleanupState ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | Anyone: @Cleanup@ takes no authority, which is the point of asserting what stops it.
  User ->
  -- | The validator's deployed reference script, as the context holds it.
  (DeployedScriptsContext -> GYTxOutRef) ->
  GYScript 'PlutusV3 ->
  -- | That validator's own @Cleanup@ redeemer. Three types, three constructors, no shared one.
  GYRedeemer ->
  -- | The state NFT identifying the UTxO to sweep.
  GYAssetClass ->
  m GYTxId
maliciousCleanupState ctx actor getRef validatorGY cleanupRedeemer stateAC = asUser actor $ do
  skeleton <-
    runReaderT
      ( do
          ref <- asks getRef
          txMustSpendStateFromRefScriptWithRedeemer ref stateAC cleanupRedeemer validatorGY
      )
      ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) $
    "Attempting to sweep real protocol state with Cleanup: " <> show stateAC
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

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

-- | MALICIOUS: resolve TWO disputes in one transaction and return ONE deposit — the @D4@ exploit.
--
-- Both disputes must name the same payout address, which is the ordinary case rather than a
-- contrivance: one person contesting two attestations opens both from the same wallet. Each dispute's
-- script instance then runs its own @D4@ against the same output list, and the single returned
-- deposit satisfies both. The second deposit leaves the script into the transaction's change, and
-- since @D1@ requires the oracle admin's signature, the transaction was built by the admin.
--
-- Index layout, which is what makes the two instances distinguishable to @D2@ and not to @D4@:
--
--   * output 0: dispute A, resolved, less its deposit
--   * output 1: dispute B, resolved, less its deposit
--   * output 2: ONE deposit, to the shared payout address
--
-- @D6@ is what refuses it. Before @D6@ this built, validated and settled.
maliciousResolveTwoDisputes ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The oracle admin, who signs: the attack needs @D1@ to pass.
  User ->
  GYAssetClass ->
  GYAssetClass ->
  DisputeVerdict ->
  m GYTxId
maliciousResolveTwoDisputes ctx admin disputeA disputeB verdict = asUser admin $ do
  skeleton <- runReaderT (maliciousResolveTwoDisputesTX (User.userPkh admin) disputeA disputeB verdict) ctx
  gyLogInfo' ("MALICIOUS" :: GYLogNamespace) "Attempting to resolve two disputes and return one deposit (D6)..."
  (gyTxBody, gyTxId) <- sendSkeleton' skeleton
  logTxBudget gyTxBody
  return gyTxId

maliciousResolveTwoDisputesTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYPubKeyHash ->
  GYAssetClass ->
  GYAssetClass ->
  DisputeVerdict ->
  m (GYTxSkeleton 'PlutusV3)
maliciousResolveTwoDisputesTX adminPkh disputeA disputeB verdict = do
  dvRef <- asks getDisputesValidatorRef
  (_oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  let onchainVerdict = disputeVerdictToOnchainVerdict verdict

  -- Each instance is told its OWN output index, so D2 is satisfied for both. D4 is the only check
  -- that reads the output list without an index, which is exactly why it was the shareable one.
  (spendsA, locksA, depositA, gyDepositTo) <- resolveOne dvRef onchainVerdict 0 disputeA
  (spendsB, locksB, _depositB, _gyDepositToB) <- resolveOne dvRef onchainVerdict 1 disputeB

  -- ONE deposit for two disputes. `depositA` and `depositB` are equal whenever the oracle's price
  -- did not move between the two openings, and the test arranges that; paying the larger of the two
  -- would be the general form and buys nothing here.
  isReturningOneDeposit <- txMustPayValueToAddress gyDepositTo depositA

  return $
    mconcat
      [ spendsA,
        spendsB,
        mustHaveRefInput oracleRef,
        locksA, -- output 0
        locksB, -- output 1
        isReturningOneDeposit, -- output 2
        mustBeSignedBy adminPkh
      ]
  where
    resolveOne dvRef onchainVerdict idx ac = do
      (disputeDatum, plutusDisputeValue) <- getDisputeDatumAndValue ac
      let dispute = extra disputeDatum
          resolvedDatum = disputeDatum {extra = OnchainTypes.resolveDispute onchainVerdict dispute}
          depositValue = valueFromLovelace (OnchainTypes.disputeDeposit dispute)
          gyRedeemer = redeemerFromPlutusData (DisputesValidator.ResolveDispute onchainVerdict idx)
      spends <- txMustSpendStateFromRefScriptWithRedeemer dvRef ac gyRedeemer disputesValidatorGY
      gyDisputeValue <- valueFromPlutus' plutusDisputeValue
      locks <-
        txMustLockStateWithInlineDatumAndValue
          disputesValidatorGY
          resolvedDatum
          (gyDisputeValue `valueMinus` depositValue)
      gyDepositTo <- addressFromPlutus' (OnchainTypes.disputeDepositTo dispute)
      return (spends, locks, depositValue, gyDepositTo)

-- | Rotate the oracle admin through the production path, signed by BOTH keys — @O5@.
--
-- 'adminInteraction' cannot do this. It runs under 'asUser', which signs with exactly one key, and
-- 'Palmares.TxBuilding.Operations.updateOracleTX' now adds the incoming admin as a required signer
-- because @O5@ demands it. So a real handover is a two-signature transaction and the harness has to
-- model that: build the body as the current admin, sign with both payment keys, submit.
--
-- The friction is the point. A rotation to a key nobody holds cannot be signed, which is the whole
-- content of @O5@: before it, a mistyped 'RotateAdminAction' ended the protocol — @O1@ then refused
-- every later update including the one that would undo it, and every open dispute became
-- unresolvable because @D1@ wants that signature too.
adminRotateInteraction ::
  (GYTxGameMonad m, HasCallStack) =>
  DeployedScriptsContext ->
  -- | The current admin, who builds and signs
  User ->
  -- | The incoming admin, who must also sign
  User ->
  m GYTxId
adminRotateInteraction txBuildingContext currentAdmin incomingAdmin = asUser currentAdmin $ do
  let interaction =
        Interaction
          { -- A KEY credential, so `O5` is satisfied by the incoming admin's signature — the branch
            -- this emulator run can actually produce. A script incoming admin proves control by
            -- spending, which needs a funded script address and is a different test.
            action = AdminAction (RotateAdminAction (V3.PubKeyCredential (userPlutusPkh incomingAdmin)) Nothing) Nothing,
            userAddresses =
              UserAddresses
                (toList $ User.userAddresses currentAdmin)
                (User.userChangeAddress currentAdmin)
                Nothing,
            recipient = Nothing
          }
  (skeleton, _) <- runReaderT (interactionToTxSkeleton interaction) txBuildingContext
  gyTxBody <- buildTxBody skeleton
  logTxBudget gyTxBody
  gyLogInfo' ("TESTLOG" :: GYLogNamespace) $
    yellowColorString ("ADMIN ROTATION, signed by both keys: \n" <> show interaction)
  submitTxConfirmed $
    signGYTxBody gyTxBody [User.userPaymentSKey currentAdmin, User.userPaymentSKey incomingAdmin]
