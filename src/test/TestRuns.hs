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
    protocolInteraction,
    adminInteraction,

    -- * Griefing / dust
    sendDustToValidator,
    lockParsingDatumAt,

    -- * Malicious builders
    maliciousMintOracleNFTWithExtraToken,
    maliciousMintOracleNFTWrongName,
    maliciousOracleUpdate,
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
import Palmares.Onchain.Protocol.Types (OracleAdminAction, OracleParams (..))
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.TxBuilding.Context
import Palmares.TxBuilding.Interactions
import Palmares.TxBuilding.Lookups (queryOracleParams)
import Palmares.TxBuilding.Operations (adminActionToOracleAdminAction, applyAdminAction)
import Palmares.TxBuilding.Skeletons
import Palmares.TxBuilding.Utils (txOutRefToV3Plutus)
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
