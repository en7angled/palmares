-- | Transaction skeleton building: profiles, ranks, memberships, achievements, oracle admin, dust cleanup.
module Palmares.TxBuilding.Operations where

import Control.Monad (unless, when)
import Control.Monad.Reader.Class (MonadReader, ask, asks)
import Data.Maybe
import Data.Typeable (cast)
import Palmares.DomainTypes.Core.Actions (AdminActionType (..))
import GHC.Stack (HasCallStack)
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.Onchain.CIP68 (CIP68Datum (..), ImageURI, MetadataFields (..), extra, getMetadataFields, mkCIP68Datum, updateCIP68DatumMetadata)
import Palmares.Onchain.Protocol.Types (OracleAdminAction (OraclePause, OracleSetFees, OracleSetMinUTxOValue, OracleUnpause))
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AchievementsRedeemer (..))
import Palmares.Onchain.Validators.MintingPolicy
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile))
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (ProfilesRedeemer (Cleanup))
import PlutusLedgerApi.V3
import Palmares.TxBuilding.Context (DeployedScriptsContext (..), getAchievementsValidatorRef, getMintingPolicyFromCtx, getMintingPolicyRef, getOracleValidatorRef, getProfilesValidatorRef)
import Palmares.TxBuilding.Conversions (cip68StandardMetadataKeys)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.TxBuilding.Lookups (getAchievementDatumAndValue, getDustUTxOs, getProfileStateDatumAndValue, getUTxOWithTokenAtAddresses, queryOracleParams)
import Palmares.TxBuilding.Skeletons
import Palmares.TxBuilding.Utils (txOutRefToV3Plutus)
import Palmares.TxBuilding.Validators

-- | Build a skeleton component that adds the oracle UTxO as a reference input.
-- Also checks whether the protocol is paused and throws 'ProtocolPaused' if so.
-- Admin operations ('updateOracleTX') bypass this function and remain unaffected.
getOracleRefInputSkeleton ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  m (GYTxSkeleton 'PlutusV3, OnchainTypes.OracleParams)
getOracleRefInputSkeleton = do
  (oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  when (OnchainTypes.opPaused oracleParams) $
    throwError (GYApplicationException ProtocolPaused)
  return (mustHaveRefInput oracleRef, oracleParams)

-- | Build a skeleton component that pays a fee if fees are configured.
getFeeSkeleton ::
  (GYTxQueryMonad m) =>
  OnchainTypes.OracleParams ->
  (OnchainTypes.FeeConfig -> Integer) ->
  m (GYTxSkeleton 'PlutusV3)
getFeeSkeleton oracle feeSelector = case OnchainTypes.opFeeConfig oracle of
  Nothing -> return mempty
  Just feeConfig -> do
    let feeAmount = feeSelector feeConfig
    let plutusFeeAddr = OnchainTypes.fcFeeAddress feeConfig
    gyFeeAddr <- addressFromPlutus' plutusFeeAddr
    txMustPayValueToAddress gyFeeAddr (valueFromLovelace feeAmount)

-- | Oracle reference input, params, fee skeleton, and validity (invalid-before-now).
-- Use when building TXs that require oracle, fee, and a validity window.
-- Min lovelace for state outputs comes from 'OnchainTypes.opMinUTxOValue' of the returned 'OracleParams'.
getOracleFeeAndValiditySkeleton ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  (OnchainTypes.FeeConfig -> Integer) ->
  m (GYTxSkeleton 'PlutusV3, OnchainTypes.OracleParams, GYTxSkeleton 'PlutusV3, GYTxSkeleton 'PlutusV3)
getOracleFeeAndValiditySkeleton feeSelector = do
  (oracleRefSkeleton, oracleParams) <- getOracleRefInputSkeleton
  feeSkeleton <- getFeeSkeleton oracleParams feeSelector
  now <- slotOfCurrentBlock
  let isValidForSafeEra = txIsValidForSafeEra now
  return (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra)

-- | Spend the User NFT for a profile (Ref AC) from the given addresses.
spendUserNFTForProfile ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
spendUserNFTForProfile profileRefAC ownAddrs = do
  gyUserAC <- gyDeriveUserFromRefAC profileRefAC
  txMustSpendFromAddress gyUserAC ownAddrs

------------------------------------------------------------------------------------------------

-- * Verify If Deployed Scripts Are Ready

------------------------------------------------------------------------------------------------

refGetters :: DeployedScriptsContext -> [GYTxOutRef]
refGetters ctx =
  [ getMintingPolicyRef ctx,
    getProfilesValidatorRef ctx,
    getAchievementsValidatorRef ctx,
    getOracleValidatorRef ctx
  ]

verifyDeployedScriptsAreReady ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  m Bool
verifyDeployedScriptsAreReady = do
  ctx <- ask
  hasRefScripts <- mapM (fmap (utxoRefScript =<<) . utxoAtTxOutRef) (refGetters ctx)
  return $ all isJust hasRefScripts

-- | Like 'verifyDeployedScriptsAreReady' but throws 'DeployedScriptsNotReady' when scripts are not ready.
ensureDeployedScriptsAreReady ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m, MonadError GYTxMonadException m) =>
  m ()
ensureDeployedScriptsAreReady = do
  ready <- verifyDeployedScriptsAreReady
  unless ready $ throwError (GYApplicationException DeployedScriptsNotReady)

------------------------------------------------------------------------------------------------

-- * OnChainProfile Operations

------------------------------------------------------------------------------------------------

updateProfileTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  -- | new description (Nothing = keep current)
  Maybe BuiltinByteString ->
  -- | new image URI
  ImageURI ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
updateProfileTX gyProfileRefAC mbNewDesc newImageURI ownAddrs = do
  pvRef <- asks getProfilesValidatorRef

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Updated profile state locked at profilesValidator
  let profileOutputIdx = 0 :: Integer

  (plutusProfileDatum, plutusProfileValue) <- getProfileStateDatumAndValue gyProfileRefAC

  -- Merge: preserve name (immutable), use new desc if provided, always use new image
  let currentFields = getMetadataFields plutusProfileDatum
      mergedFields =
        Metadata222
          { metadataName = metadataName currentFields,
            metadataDescription = fromMaybe (metadataDescription currentFields) mbNewDesc,
            metadataImageURI = newImageURI
          }
      updateRedeemer = UpdateProfile mergedFields profileOutputIdx

  let gyRedeemer = redeemerFromPlutusData updateRedeemer
  spendsProfileRefNFT <- txMustSpendStateFromRefScriptWithRedeemer pvRef gyProfileRefAC gyRedeemer profilesValidatorGY
  gyProfileUserAC <- gyDeriveUserFromRefAC gyProfileRefAC
  spendsProfileUserNFT <- txMustSpendFromAddress gyProfileUserAC ownAddrs
  let newCip68Datum = updateCIP68DatumMetadata mergedFields plutusProfileDatum
  gyProfileValue <- valueFromPlutus' plutusProfileValue

  -- Output 0: Updated profile state
  isLockingUpdatedProfileState <- txMustLockStateWithInlineDatumAndValue profilesValidatorGY newCip68Datum gyProfileValue
  return $
    mconcat
      [ spendsProfileUserNFT, -- Input (no output index)
        spendsProfileRefNFT, -- Input (no output index)
        isLockingUpdatedProfileState -- Output 0: Updated profile state
      ]

-- NOTE: deleteProfileTX is intentionally not implemented to preserve lineage integrity.
-- An attestation record is a permanent historical fact and must stay resolvable.


hasUserNFTAt :: (GYTxQueryMonad m) => GYAssetClass -> [GYAddress] -> m Bool
hasUserNFTAt nftAC addrs =
  catchError
    (True <$ getUTxOWithTokenAtAddresses nftAC addrs ProfileNotFound)
    ( \e -> case e of
        GYApplicationException ex | Just ProfileNotFound <- cast ex -> return False
        _ -> throwError e
    )

-- | Update the end date of a membership interval (org or practitioner).
-- Corresponds to 'UpdateEndDate' spending (no minting, no fee).
-- Caller must have either the organization User NFT or the practitioner User NFT.
--
-- Output index layout:
--   Output 0: Updated interval with new end date
--
-- When 'validityOverride' is 'Just' a skeleton, it is used as the tx validity
-- instead of 'validitySkeletonForNewEndDate'. Used only by tests (e.g. to trigger TD failure).
-- * Achievement Operations

------------------------------------------------------------------------------------------------

-- | Award an achievement to a practitioner.
-- The awarder (awardedBy) spends their User NFT to authorize.
-- Corresponds to 'NewAchievement' minting.
--
-- Output index layout:
--   Output 0: Achievement NFT locked at achievementsValidator
--   Output 1 (optional): Fee payment
awardAchievementTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Profile ID of the practitioner receiving the achievement
  GYAssetClass ->
  -- | Profile ID of the awarder (org or practitioner)
  GYAssetClass ->
  -- | CIP-68 metadata fields (name, description, image)
  MetadataFields ->
  -- | Additional metadata key-value pairs
  [(BuiltinByteString, BuiltinByteString)] ->
  -- | Achievement date
  POSIXTime ->
  -- | Awarder's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
awardAchievementTX gyAwardedToProfileId gyAwardedByProfileId metadata otherMetadata achievementDate ownAddrs = do
  mapM_
    ( \(k, _) ->
        when (k `elem` cip68StandardMetadataKeys) $
          throwError (GYApplicationException AchievementOtherMetadataReservedKeys)
    )
    otherMetadata
  mpGY <- asks getMintingPolicyFromCtx
  mpRef <- asks getMintingPolicyRef
  (oracleRefSkeleton, oracleParams, feeSkeleton, isInvalidBeforeNow) <- getOracleFeeAndValiditySkeleton OnchainTypes.fcAttestationFee
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  -- Get a seed TxOutRef for uniqueness
  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
  let seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef

  spendsAwarderUserNFT <- spendUserNFTForProfile gyAwardedByProfileId ownAddrs

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Achievement NFT locked at achievementsValidator
  -- Output 1 (optional): Fee payment
  let achievementOutputIdx = 0 :: Integer

  let redeemer =
        NewAchievement
          seedTxOutRefPlutus
          metadata
          otherMetadata
          (assetClassToPlutus gyAwardedToProfileId)
          (assetClassToPlutus gyAwardedByProfileId)
          achievementDate
          achievementOutputIdx
  let gyRedeemer = redeemerFromPlutusData redeemer

  -- Generate achievement NFT AC
  (gyAchievementRefAC, _gyAchievementUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingAchievementNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyAchievementRefAC

  -- Build achievement datum
  let achievementInfo =
        OnchainTypes.OnchainAchievement
          { OnchainTypes.achievementId = assetClassToPlutus gyAchievementRefAC,
            OnchainTypes.achievementAwardedTo = assetClassToPlutus gyAwardedToProfileId,
            OnchainTypes.achievementAwardedBy = assetClassToPlutus gyAwardedByProfileId,
            OnchainTypes.achievementDate = achievementDate,
            OnchainTypes.achievementIsAccepted = False
          }
  let achievementDatum = mkCIP68Datum achievementInfo metadata otherMetadata

  -- Output 0: Achievement NFT
  isLockingAchievement <-
    txMustLockStateWithInlineDatumAndValue
      achievementsValidatorGY
      achievementDatum
      (valueSingleton gyAchievementRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO, -- Input (no output index)
          spendsAwarderUserNFT, -- Input (no output index)
          isInvalidBeforeNow, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingAchievementNFT, -- Mint (no output index)
          isLockingAchievement, -- Output 0: Achievement NFT
          feeSkeleton -- Output 1 (optional): Fee payment
        ],
      gyAchievementRefAC
    )

-- | Accept an achievement (practitioner consent).
-- Corresponds to 'AcceptAchievement' spending (no minting).
--
-- Output index layout:
--   Output 0: Updated achievement with isAccepted = True
acceptAchievementTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Achievement NFT AC
  GYAssetClass ->
  -- | Practitioner's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
acceptAchievementTX gyAchievementAC ownAddrs = do
  avRef <- asks getAchievementsValidatorRef

  -- Look up the achievement
  (achievementDatum, achievementValue) <- getAchievementDatumAndValue gyAchievementAC

  -- Spend practitioner User NFT
  let practitionerProfileRefAC = OnchainTypes.achievementAwardedTo (extra achievementDatum)
  gyPractitionerProfileRefAC <- assetClassFromPlutus' practitionerProfileRefAC
  gyPractitionerUserAC <- gyDeriveUserFromRefAC gyPractitionerProfileRefAC
  spendsPractitionerUserNFT <- txMustSpendFromAddress gyPractitionerUserAC ownAddrs

  -- Compute updated achievement.
  -- The already-accepted guard is inlined from the Belt System's
  -- TxBuilding.SafeOnchainLogic.safeAcceptAchievement (a module the extraction skips). Keeping it
  -- here preserves the 400 that a second accept returns; without it the build would succeed and
  -- submit a no-op transaction, because the validator's expected output datum is the same either
  -- way. The on-chain half of this (fix #4) is Plan B's.
  when (OnchainTypes.achievementIsAccepted (extra achievementDatum)) $
    throwError (GYApplicationException AchievementAlreadyAccepted)
  let updatedAchievementDatum =
        achievementDatum {extra = (extra achievementDatum) {OnchainTypes.achievementIsAccepted = True}}

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Updated achievement
  let achievementOutputIdx = 0 :: Integer

  -- Build AttestationsValidator redeemer
  let avRedeemer = redeemerFromPlutusData $ AcceptAchievement achievementOutputIdx

  -- Spend the achievement from achievements validator
  spendsAchievement <- txMustSpendStateFromRefScriptWithRedeemer avRef gyAchievementAC avRedeemer achievementsValidatorGY

  gyAchievementValue <- valueFromPlutus' achievementValue
  -- Output 0: Updated achievement
  isLockingUpdatedAchievement <-
    txMustLockStateWithInlineDatumAndValue
      achievementsValidatorGY
      updatedAchievementDatum
      gyAchievementValue

  return $
    mconcat
      [ spendsPractitionerUserNFT, -- Input (no output index)
        spendsAchievement, -- Input (no output index)
        isLockingUpdatedAchievement -- Output 0: Updated achievement
      ]

------------------------------------------------------------------------------------------------

-- * Oracle Management Operations

------------------------------------------------------------------------------------------------

-- | Build a transaction skeleton that updates oracle parameters based on an admin action.
-- Queries the current oracle params, applies the action delta, and builds spend + re-lock skeletons.
updateOracleTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  AdminActionType ->
  m (GYTxSkeleton 'PlutusV3)
updateOracleTX adminAction = do
  ovRef <- asks getOracleValidatorRef
  (currentParams, oracleRef, oracleValue) <- queryOracleParams
  let actionPlutus = adminActionToOracleAdminAction adminAction
  let gyRedeemer = redeemerFromPlutusData (OracleUpdate 0 actionPlutus)

  -- Apply the action to derive the new oracle params (must match on-chain applyOracleAdminAction)
  let newParams = applyAdminAction adminAction currentParams

  -- Convert admin PKH from Plutus to GY for required signer
  gyAdminPkh <- pubKeyHashFromPlutus' (OnchainTypes.opAdminPkh currentParams)

  -- Spend the current oracle UTxO
  let currentDatum = datumFromPlutusData currentParams
  let spendOracle = txMustSpendFromRefScriptWithKnownDatum ovRef oracleRef currentDatum gyRedeemer oracleValidatorGY

  -- Re-lock oracle with new datum and same value
  lockOracle <- txMustLockStateWithInlineDatumAndValue oracleValidatorGY newParams oracleValue

  -- Require admin signature (on-chain validator checks txInfoSignatories)
  let requireAdminSig = mustBeSignedBy gyAdminPkh

  return $ mconcat [spendOracle, lockOracle, requireAdminSig]

-- | Map off-chain admin action to on-chain OracleAdminAction (for the redeemer).
adminActionToOracleAdminAction :: AdminActionType -> OracleAdminAction
adminActionToOracleAdminAction PauseProtocolAction = OraclePause
adminActionToOracleAdminAction UnpauseProtocolAction = OracleUnpause
adminActionToOracleAdminAction (SetFeesAction mFeeConfig) = OracleSetFees mFeeConfig
adminActionToOracleAdminAction (SetMinUTxOValueAction lovelace) = OracleSetMinUTxOValue lovelace

-- | Apply an admin action delta to current oracle params to produce new params.
-- Must stay in sync with on-chain 'Onchain.Protocol.Types.applyOracleAdminAction'.
applyAdminAction :: AdminActionType -> OnchainTypes.OracleParams -> OnchainTypes.OracleParams
applyAdminAction PauseProtocolAction params = params {OnchainTypes.opPaused = True}
applyAdminAction UnpauseProtocolAction params = params {OnchainTypes.opPaused = False}
applyAdminAction (SetFeesAction mFeeConfig) params = params {OnchainTypes.opFeeConfig = mFeeConfig}
applyAdminAction (SetMinUTxOValueAction lovelace) params = params {OnchainTypes.opMinUTxOValue = lovelace}

------------------------------------------------------------------------------------------------

-- * Dust / Cleanup Operations

------------------------------------------------------------------------------------------------

-- | Build spend skeletons for dust UTxOs at one validator (for cleanup).
dustSpendsForValidatorSkeleton ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  (DeployedScriptsContext -> GYTxOutRef) ->
  GYScript 'PlutusV3 ->
  GYRedeemer ->
  m [GYTxSkeleton 'PlutusV3]
dustSpendsForValidatorSkeleton getRef validatorGY cleanupRedeemer = do
  ref <- asks getRef
  addr <- scriptAddress validatorGY
  ctx <- ask
  let protocolCS = mintingPolicyCurrencySymbol (getMintingPolicyFromCtx ctx)
  dust <- getDustUTxOs addr protocolCS
  return $ map (\utxo -> txMustSpendUTxOFromRefScript ref utxo cleanupRedeemer validatorGY) dust

-- | Sweep dust UTxOs from all deployed validator addresses.
-- Returns the number of dust UTxOs found and the transaction skeleton.
-- Anyone can call this — the on-chain 'Cleanup' redeemer is permissionless.
-- The ADA locked in the dust UTxOs is returned to the caller.
cleanupDustTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  m (GYTxSkeleton 'PlutusV3, Int)
cleanupDustTX = do
  configs <-
    sequence
      [ dustSpendsForValidatorSkeleton getProfilesValidatorRef profilesValidatorGY (redeemerFromPlutusData ProfilesValidator.Cleanup),
        dustSpendsForValidatorSkeleton getAchievementsValidatorRef achievementsValidatorGY (redeemerFromPlutusData Cleanup)
      ]
  let allSpends = concat configs
      dustCount = sum (map length configs)
  when (dustCount == 0) $
    throwError (GYApplicationException NoDustFound)
  return (mconcat allSpends, dustCount)
