-- | Transaction skeleton building: profiles, ranks, memberships, attestations, oracle admin, dust cleanup.
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
import Palmares.Onchain.Protocol.Lookup qualified as Lookup
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer (..))
import Palmares.Onchain.Validators.MintingPolicy
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile))
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (ProfilesRedeemer (Cleanup))
import PlutusLedgerApi.V3
import Palmares.TxBuilding.Context (DeployedScriptsContext (..), getAttestationsValidatorRef, getMintingPolicyFromCtx, getMintingPolicyRef, getOracleValidatorRef, getProfilesValidatorRef)
import Palmares.TxBuilding.Conversions (cip68StandardMetadataKeys)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.TxBuilding.Lookups (getAttestationDatumAndValue, getDustUTxOs, getProfileStateDatumAndValue, getUTxOWithTokenAtAddresses, queryOracleParams)
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
-- Takes a 'MintAction', never a @(FeeConfig -> Integer)@ selector — inherited fix #1. The selector
-- shape is what let the Belt System's interval fee charge the wrong field: with a selector every call
-- site names a field, and one of them named the wrong one. 'Lookup.feeFor' is now the single place on
-- chain or off where a 'FeeConfig' field is named, and this function calls it, so the off-chain fee
-- and the on-chain check read the same number from the same code.
getFeeSkeleton ::
  (GYTxQueryMonad m) =>
  OnchainTypes.OracleParams ->
  OnchainTypes.MintAction ->
  m (GYTxSkeleton 'PlutusV3)
getFeeSkeleton oracle action = case OnchainTypes.opFeeConfig oracle of
  Nothing -> return mempty
  Just feeConfig -> do
    let feeAmount = Lookup.feeFor action feeConfig
    let plutusFeeAddr = OnchainTypes.fcFeeAddress feeConfig
    gyFeeAddr <- addressFromPlutus' plutusFeeAddr
    txMustPayValueToAddress gyFeeAddr (valueFromLovelace feeAmount)

-- | Oracle reference input, params, fee skeleton, and validity (invalid-before-now).
-- Use when building TXs that require oracle, fee, and a validity window.
-- Min lovelace for state outputs comes from 'OnchainTypes.opMinUTxOValue' of the returned 'OracleParams'.
getOracleFeeAndValiditySkeleton ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  OnchainTypes.MintAction ->
  m (GYTxSkeleton 'PlutusV3, OnchainTypes.OracleParams, GYTxSkeleton 'PlutusV3, GYTxSkeleton 'PlutusV3)
getOracleFeeAndValiditySkeleton action = do
  (oracleRefSkeleton, oracleParams) <- getOracleRefInputSkeleton
  feeSkeleton <- getFeeSkeleton oracleParams action
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
    getAttestationsValidatorRef ctx,
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

-- * Attestation Operations

------------------------------------------------------------------------------------------------

-- | Issue an attestation about a subject.
-- The issuer spends their User NFT to authorize.
-- Corresponds to 'NewAttestation' minting.
--
-- Output index layout:
--   Output 0: Attestation NFT locked at attestationsValidator
--   Output 1 (optional): Fee payment
issueAttestationTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Profile ID of the subject the attestation is about
  GYAssetClass ->
  -- | Profile ID of the issuer
  GYAssetClass ->
  -- | CIP-68 metadata fields (name, description, image)
  MetadataFields ->
  -- | Additional metadata key-value pairs
  [(BuiltinByteString, BuiltinByteString)] ->
  -- | Attestation date
  POSIXTime ->
  -- | Issuer's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
issueAttestationTX gySubjectProfileId gyIssuerProfileId metadata otherMetadata attestationDate ownAddrs = do
  mapM_
    ( \(k, _) ->
        when (k `elem` cip68StandardMetadataKeys) $
          throwError (GYApplicationException AttestationOtherMetadataReservedKeys)
    )
    otherMetadata
  mpGY <- asks getMintingPolicyFromCtx
  mpRef <- asks getMintingPolicyRef
  (oracleRefSkeleton, oracleParams, feeSkeleton, isInvalidBeforeNow) <- getOracleFeeAndValiditySkeleton OnchainTypes.MintActionAttestation
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  -- Get a seed TxOutRef for uniqueness
  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
  let seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef

  spendsIssuerUserNFT <- spendUserNFTForProfile gyIssuerProfileId ownAddrs

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Attestation NFT locked at attestationsValidator
  -- Output 1 (optional): Fee payment
  let attestationOutputIdx = 0 :: Integer

  let redeemer =
        NewAttestation
          seedTxOutRefPlutus
          metadata
          otherMetadata
          (assetClassToPlutus gySubjectProfileId)
          (assetClassToPlutus gyIssuerProfileId)
          attestationDate
          attestationOutputIdx
  let gyRedeemer = redeemerFromPlutusData redeemer

  -- Generate attestation NFT AC
  (gyAttestationRefAC, _gyAttestationUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingAttestationNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyAttestationRefAC

  -- Build attestation datum
  let attestationInfo =
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus gyAttestationRefAC,
            OnchainTypes.attestationSubject = assetClassToPlutus gySubjectProfileId,
            OnchainTypes.attestationIssuer = assetClassToPlutus gyIssuerProfileId,
            OnchainTypes.attestationDate = attestationDate,
            OnchainTypes.attestationIsAccepted = False
          }
  let attestationDatum = mkCIP68Datum attestationInfo metadata otherMetadata

  -- Output 0: Attestation NFT
  isLockingAttestation <-
    txMustLockStateWithInlineDatumAndValue
      attestationsValidatorGY
      attestationDatum
      (valueSingleton gyAttestationRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO, -- Input (no output index)
          spendsIssuerUserNFT, -- Input (no output index)
          isInvalidBeforeNow, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingAttestationNFT, -- Mint (no output index)
          isLockingAttestation, -- Output 0: Attestation NFT
          feeSkeleton -- Output 1 (optional): Fee payment
        ],
      gyAttestationRefAC
    )

-- | Accept an attestation (the subject's countersignature).
-- Corresponds to 'AcceptAttestation' spending (no minting).
--
-- Output index layout:
--   Output 0: Updated attestation with isAccepted = True
acceptAttestationTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Attestation NFT AC
  GYAssetClass ->
  -- | Subject's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
acceptAttestationTX gyAttestationAC ownAddrs = do
  avRef <- asks getAttestationsValidatorRef

  -- Look up the attestation
  (attestationDatum, attestationValue) <- getAttestationDatumAndValue gyAttestationAC

  -- Spend the subject's User NFT
  let subjectProfileRefAC = OnchainTypes.attestationSubject (extra attestationDatum)
  gySubjectProfileRefAC <- assetClassFromPlutus' subjectProfileRefAC
  gySubjectUserAC <- gyDeriveUserFromRefAC gySubjectProfileRefAC
  spendsSubjectUserNFT <- txMustSpendFromAddress gySubjectUserAC ownAddrs

  -- Compute updated attestation.
  -- The already-accepted guard is inlined from the inherited
  -- TxBuilding.SafeOnchainLogic.safeAcceptAttestation (a module the extraction skips). Keeping it
  -- here preserves the 400 that a second accept returns; without it the build would succeed and
  -- submit a no-op transaction, because the validator's expected output datum is the same either
  -- way. The on-chain half of this (fix #4) is Plan B's.
  when (OnchainTypes.attestationIsAccepted (extra attestationDatum)) $
    throwError (GYApplicationException AttestationAlreadyAccepted)
  let updatedAttestationDatum =
        attestationDatum {extra = (extra attestationDatum) {OnchainTypes.attestationIsAccepted = True}}

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Updated attestation
  let attestationOutputIdx = 0 :: Integer

  -- Build AttestationsValidator redeemer
  let avRedeemer = redeemerFromPlutusData $ AcceptAttestation attestationOutputIdx

  -- Spend the attestation from attestations validator
  spendsAttestation <- txMustSpendStateFromRefScriptWithRedeemer avRef gyAttestationAC avRedeemer attestationsValidatorGY

  gyAttestationValue <- valueFromPlutus' attestationValue
  -- Output 0: Updated attestation
  isLockingUpdatedAttestation <-
    txMustLockStateWithInlineDatumAndValue
      attestationsValidatorGY
      updatedAttestationDatum
      gyAttestationValue

  return $
    mconcat
      [ spendsSubjectUserNFT, -- Input (no output index)
        spendsAttestation, -- Input (no output index)
        isLockingUpdatedAttestation -- Output 0: Updated attestation
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
        dustSpendsForValidatorSkeleton getAttestationsValidatorRef attestationsValidatorGY (redeemerFromPlutusData Cleanup)
      ]
  let allSpends = concat configs
      dustCount = sum (map length configs)
  when (dustCount == 0) $
    throwError (GYApplicationException NoDustFound)
  return (mconcat allSpends, dustCount)
