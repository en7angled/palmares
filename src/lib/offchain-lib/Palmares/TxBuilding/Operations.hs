-- | Transaction skeleton building: profiles, ranks, memberships, attestations, oracle admin, dust cleanup.
module Palmares.TxBuilding.Operations where

import Control.Monad (unless, when)
import Control.Monad.Reader.Class (MonadReader, ask, asks)
import Data.Maybe
import Data.Typeable (cast)
import Palmares.DomainTypes.Core.Actions (AdminActionType (..), ClaimWitness (..))
import GHC.Stack (HasCallStack)
import GeniusYield.TxBuilder
import GeniusYield.Types
import GeniusYield.Types.Script.ScriptHash (scriptHashFromPlutus)
import Palmares.Onchain.CIP68 (CIP68Datum (..), ImageURI, MetadataFields (..), extra, getMetadataFields, mkCIP68Datum, updateCIP68DatumMetadata)
import Palmares.Onchain.Protocol.Types (OracleAdminAction (OraclePause, OracleSetAdmin, OracleSetDisputeDeposit, OracleSetFees, OracleSetMinUTxOValue, OracleUnpause))
import Palmares.Onchain.Protocol.Lookup qualified as Lookup
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer (..))
import Palmares.Onchain.Validators.DisputesValidator qualified as DisputesValidator (DisputesRedeemer (Cleanup, ResolveDispute))
import Palmares.Onchain.Validators.MintingPolicy
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile))
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (ProfilesRedeemer (Cleanup))
import PlutusLedgerApi.V3
import Palmares.TxBuilding.Context (DeployedScriptsContext (..), getAttestationsValidatorRef, getDisputesValidatorRef, getMintingPolicyFromCtx, getMintingPolicyRef, getOracleValidatorRef, getProfilesValidatorRef, getProtocolParamsFromCtx)
import Palmares.TxBuilding.Conversions (cip68StandardMetadataKeys, claimWitnessToTxInWitness)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
import Palmares.TxBuilding.Lookups (ensureSubjectProfileExists, getAttestationDatumAndValue, getDisputeDatumAndValue, getDustUTxOs, getOpenDisputesForAttestation, getProfileStateDatumAndValue, getUTxOWithTokenAtAddresses, queryOracleParams)
import Palmares.TxBuilding.Skeletons
import Palmares.TxBuilding.Utils (pPOSIXTimeFromGYSlot, txOutRefToV3Plutus)
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

-- | Oracle reference input and validity window, with the pause check and __no fee__.
--
-- The fee-free sibling of 'getOracleFeeAndValiditySkeleton', for the two operations that mint
-- nothing: a profile update and an attestation acceptance invoke no minting policy, so 'Lookup.feeFor'
-- has no action to price them by and charging one of the mint fees would be charging for something
-- else entirely.
--
-- __Both of those operations used to attach neither.__ Only 'issueAttestationTX' read the oracle, so
-- @opPaused@ stopped an issuance and nothing else: the protocol could not actually be paused, which
-- is the only lever there is when something is going wrong on chain.
getOracleAndValiditySkeleton ::
  (GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  m (GYTxSkeleton 'PlutusV3, GYTxSkeleton 'PlutusV3)
getOracleAndValiditySkeleton = do
  (oracleRefSkeleton, _oracleParams) <- getOracleRefInputSkeleton
  now <- slotOfCurrentBlock
  return (oracleRefSkeleton, txIsValidForSafeEra now)

-- | Spend the User NFT for a profile (Ref AC) from the given addresses, with a key witness.
--
-- The key witness is the ordinary wallet case. A token held AT a script address needs the script's
-- own witness, which 'txMustSpendFromAddress' now takes as a parameter; threading that choice up
-- through the domain actions for update, accept and dispute is not this task's.
spendUserNFTForProfile ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3)
spendUserNFTForProfile profileRefAC ownAddrs = do
  gyUserAC <- gyDeriveUserFromRefAC profileRefAC
  txMustSpendFromAddress gyUserAC ownAddrs GYTxInWitnessKey

------------------------------------------------------------------------------------------------

-- * Verify If Deployed Scripts Are Ready

------------------------------------------------------------------------------------------------

refGetters :: DeployedScriptsContext -> [GYTxOutRef]
refGetters ctx =
  [ getMintingPolicyRef ctx,
    getProfilesValidatorRef ctx,
    getAttestationsValidatorRef ctx,
    getDisputesValidatorRef ctx,
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
  -- Refuses while the protocol is paused, which until now it did not: see
  -- 'getOracleAndValiditySkeleton'.
  (oracleRefSkeleton, isValidForSafeEra) <- getOracleAndValiditySkeleton

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
  spendsProfileUserNFT <-
    txMustSpendFromAddress gyProfileUserAC ownAddrs GYTxInWitnessKey
  let newCip68Datum = updateCIP68DatumMetadata mergedFields plutusProfileDatum
  gyProfileValue <- valueFromPlutus' plutusProfileValue

  -- Output 0: Updated profile state
  isLockingUpdatedProfileState <- txMustLockStateWithInlineDatumAndValue profilesValidatorGY newCip68Datum gyProfileValue
  return $
    mconcat
      [ spendsProfileUserNFT, -- Input (no output index)
        spendsProfileRefNFT, -- Input (no output index)
        isValidForSafeEra, -- Validity (no output index)
        oracleRefSkeleton, -- Reference input: oracle UTxO
        isLockingUpdatedProfileState -- Output 0: Updated profile state
      ]

-- NOTE: deleteProfileTX is intentionally not implemented to preserve lineage integrity.
-- An attestation record is a permanent historical fact and must stay resolvable.

-- | The input or the signature that proves control of a claimed credential, which is the whole of
-- the identity claim: /prove you can spend as that credential/.
--
-- Two arms, because a 'Credential' is one of two things and the proof differs:
--
--   * a __key__ credential is proven by the transaction carrying its signature, so this adds a
--     required signer and @Mp3@ finds it in @txInfoSignatories@;
--   * a __script__ credential is proven by the transaction spending an input that script governs —
--     if the ledger is spending it, the script's own condition was already satisfied, before our
--     validator ran. The caller supplies the witness because a native multisig has no redeemer for
--     us to invent and a Plutus script's redeemer is its own business.
--
-- __The lookup happens before anything is built__, and that is the point rather than an
-- optimisation: a Plutus script that only votes or withdraws holds no UTxO at its own address and
-- cannot claim in one transaction. Left to the balancer that is an unreadable failure; here it is a
-- 400 that names the script and says the fix (send yourself a UTxO at that address first). A key
-- witness offered for a script credential lands in the same refusal, because it cannot spend the
-- input either.
--
-- @utxosAtPaymentCredential@ and not an address lookup, so a script UTxO that carries a staking part
-- is found too — the script's own address with any stake credential on it, which is the right
-- breadth because the PAYMENT half is what spending authenticates.
--
-- That last clause used to read "the same breadth @checkCredentialControl@ has on chain", and after
-- commit @7e6b02a@ it was false in a way worth recording: the on-chain rule deliberately has LESS
-- breadth now. It used to accept a credential found in the staking half of a spent input too, which
-- made every script credential claimable by anyone, because the staking half of an address is
-- attacker-chosen data the ledger never witnesses. The code here was always correct — a
-- payment-credential lookup is exactly the right mirror — but the stated justification had become a
-- licence for the hole that was closed.
claimProofSkeleton ::
  (GYTxQueryMonad m) =>
  Credential ->
  Maybe ClaimWitness ->
  m (GYTxSkeleton 'PlutusV3)
claimProofSkeleton (PubKeyCredential pkh) _ = do
  gyPkh <- pubKeyHashFromPlutus' pkh
  return (mustBeSignedBy gyPkh)
claimProofSkeleton (ScriptCredential sh) mWitness = do
  gySh <- either (const (throwError (GYApplicationException CredentialMalformed))) return (scriptHashFromPlutus sh)
  utxos <- utxosAtPaymentCredential (GYPaymentCredentialByScript gySh) Nothing
  case (filter (isNothing . utxoRefScript) (utxosToList utxos), mWitness) of
    (spendable : _, Just witness@(WitnessSimpleScript _)) ->
      return (mustHaveInput (GYTxIn (utxoRef spendable) (claimWitnessToTxInWitness witness)))
    (spendable : _, Just witness@(WitnessPlutusScript _ _)) ->
      return (mustHaveInput (GYTxIn (utxoRef spendable) (claimWitnessToTxInWitness witness)))
    _ -> throwError (GYApplicationException (ScriptCredentialHasNoUtxo gySh))

-- | Mint a profile, optionally claiming a Cardano credential.
--
-- Corresponds to 'MintProfile' minting, and it is the operation whose absence made every other user
-- operation unreachable: all three took a profile's Ref 'GYAssetClass' as input and nothing could
-- create one.
--
-- __Both CIP-68 tokens are minted__, unlike 'issueAttestationTX' which mints only the ref token: a
-- profile's user token IS the authority instrument this protocol runs on, while an attestation has
-- no owner that acts on its behalf. The user token is not paid anywhere explicitly, so it lands in
-- the balancer's change output — in the claimant's wallet, which is where authority belongs.
--
-- Output index layout:
--   Output 0: Profile state (ref NFT + datum) locked at profilesValidator
--   Output 1 (optional): Fee payment
claimProfileTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | What kind of actor this profile stands for
  OnchainTypes.OnchainProfileKind ->
  -- | The credential claimed, if any. 'Nothing' for a Community or an Auditor, which correspond to
  -- no on-chain credential and which the read layer must present as @unclaimed@, never as verified.
  Maybe Credential ->
  -- | How control of a script credential is proven. Ignored for a key credential.
  Maybe ClaimWitness ->
  -- | CIP-68 metadata fields (name, description, image)
  MetadataFields ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
claimProfileTX kind mCredential mWitness metadata = do
  ctx <- ask
  let mpGY = getMintingPolicyFromCtx ctx
      mpRef = getMintingPolicyRef ctx
  (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionProfile
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  -- Resolved first, so a claim that cannot be proven never reaches the balancer.
  claimProof <- maybe (return mempty) (`claimProofSkeleton` mWitness) mCredential

  -- Get a seed TxOutRef for uniqueness
  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
  let seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Profile state locked at profilesValidator
  -- Output 1 (optional): Fee payment
  let profileOutputIdx = 0 :: Integer

  let gyRedeemer = redeemerFromPlutusData (MintProfile seedTxOutRefPlutus kind mCredential metadata profileOutputIdx)

  (gyProfileRefAC, _gyProfileUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingProfileNFTs <- txMustMintCIP68UserAndRef mpRef mpGY gyRedeemer gyProfileRefAC

  let profileInfo =
        OnchainTypes.OnchainProfile
          { OnchainTypes.profileId = assetClassToPlutus gyProfileRefAC,
            OnchainTypes.profileKind = kind,
            OnchainTypes.profileCredential = mCredential,
            OnchainTypes.protocolParams = getProtocolParamsFromCtx ctx
          }
  let profileDatum = mkCIP68Datum profileInfo metadata []

  -- Output 0: Profile state
  isLockingProfileState <-
    txMustLockStateWithInlineDatumAndValue
      profilesValidatorGY
      profileDatum
      (valueSingleton gyProfileRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO, -- Input (no output index)
          claimProof, -- Input or required signer (no output index)
          isValidForSafeEra, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingProfileNFTs, -- Mint (no output index)
          isLockingProfileState, -- Output 0: Profile state
          feeSkeleton -- Output 1 (optional): Fee payment
        ],
      gyProfileRefAC
    )

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
-- | Is this claimed period transposed? __The only check the claimed period gets.__
--
-- A named top-level function and not an inline guard, because it is the entire validation rule for a
-- field the minting policy deliberately does not check — and an inline guard inside a
-- 'GYTxUserQueryMonad' action is a rule no test can reach without a provider. A review found that
-- this path had zero coverage; this is what makes it testable.
--
-- 'Nothing' is not inverted: omitting the period is the normal case. Equal bounds are not inverted
-- either — a membership that began and ended on one day is a claim someone may legitimately make.
claimedPeriodIsInverted :: Maybe (POSIXTime, POSIXTime) -> Bool
claimedPeriodIsInverted (Just (periodFrom, periodTo)) = periodFrom > periodTo
claimedPeriodIsInverted Nothing = False

issueAttestationTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Profile ID of the subject the attestation is about
  GYAssetClass ->
  -- | Profile ID of the issuer
  GYAssetClass ->
  -- | What the attestation asserts about its subject
  OnchainTypes.AttestationKind ->
  -- | CIP-68 metadata fields (name, description, image)
  MetadataFields ->
  -- | Additional metadata key-value pairs
  [(BuiltinByteString, BuiltinByteString)] ->
  -- | The claimed period, self-reported. Bounded by nothing, and that is the point.
  Maybe (POSIXTime, POSIXTime) ->
  -- | Issuer's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
issueAttestationTX gySubjectProfileId gyIssuerProfileId kind metadata otherMetadata claimedPeriod ownAddrs = do
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

  -- Review Focus item 3, off-chain half. The minting policy checks only the subject's currency
  -- symbol, and nothing in this protocol burns, so an attestation about a profile that does not exist
  -- is permanently pending AND permanently unremovable. See 'ensureSubjectProfileExists'.
  ensureSubjectProfileExists gySubjectProfileId

  -- The off-chain half of inherited fix #4, finished. @Ml@ requires the date to be CONTAINED in the
  -- validity interval, and the interval this transaction carries is [tip, tip + safeEraTime] — so a
  -- caller-supplied date could only ever agree with the tip or be refused, which made it a field
  -- whose only possible values were one correct one and a 400. It is now DERIVED from the tip and is
  -- not a request field at all: the date an attestation carries is the moment the chain accepted it,
  -- which is the only thing the chain can honestly say about when. A claim about the past goes in
  -- @claimedPeriod@, published as self-reported.
  now <- slotOfCurrentBlock
  attestationDate <- pPOSIXTimeFromGYSlot now

  -- The claimed period gets EXACTLY ONE check, and deliberately not a window check: a period that
  -- begins before this transaction is the normal case — "a member since March 2024" — which is the
  -- whole reason the field exists separately from the date above. Transposed bounds are the one thing
  -- that cannot be a legitimate claim, and the only one a client can be told about, because the
  -- minting policy carries the period through unvalidated on purpose.
  when (claimedPeriodIsInverted claimedPeriod) $
    throwError (GYApplicationException AttestationPeriodInverted)

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
          kind
          attestationDate
          claimedPeriod
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
            OnchainTypes.attestationKind = kind,
            OnchainTypes.attestationDate = attestationDate,
            OnchainTypes.attestationPeriod = claimedPeriod,
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
  -- Refuses while the protocol is paused, which until now it did not: see
  -- 'getOracleAndValiditySkeleton'.
  (oracleRefSkeleton, isValidForSafeEra) <- getOracleAndValiditySkeleton

  -- Look up the attestation
  (attestationDatum, attestationValue) <- getAttestationDatumAndValue gyAttestationAC

  -- Spend the subject's User NFT
  let subjectProfileRefAC = OnchainTypes.attestationSubject (extra attestationDatum)
  gySubjectProfileRefAC <- assetClassFromPlutus' subjectProfileRefAC
  gySubjectUserAC <- gyDeriveUserFromRefAC gySubjectProfileRefAC
  spendsSubjectUserNFT <- txMustSpendFromAddress gySubjectUserAC ownAddrs GYTxInWitnessKey

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
        isValidForSafeEra, -- Validity (no output index)
        oracleRefSkeleton, -- Reference input: oracle UTxO
        isLockingUpdatedAttestation -- Output 0: Updated attestation
      ]

------------------------------------------------------------------------------------------------

-- * Dispute Operations

------------------------------------------------------------------------------------------------

-- | Open a dispute against an attestation: lock the deposit, record what was paid, prove who paid it.
--
-- Corresponds to 'OpenDispute' minting. __Nothing here touches the attestation being disputed__ — it
-- is not spent, not re-datumed, not even read as an input by the validator — which is what lets a
-- dispute exist without the subject's or the issuer's cooperation, and what keeps the attestation
-- path's ExUnits unchanged.
--
-- __Only the ref token is minted, no user token__ (@Md2@): a user token is authority to do
-- something, and there is nothing a dispute's holder may do. Resolution is the oracle admin's, and
-- the deposit returns to an address fixed in the datum.
--
-- __The duplicate check is a courtesy, not a guarantee.__ 'getOpenDisputesForAttestation' is an
-- off-chain read of the Disputes validator address, and nothing on chain refuses a second open
-- dispute — see that function and 'Palmares.Onchain.Validators.DisputesValidator'. A client building
-- its own transaction is not refused; what bounds the spam is that N disputes cost N deposits.
--
-- Output index layout:
--   Output 0: Dispute NFT + deposit locked at disputesValidator
openDisputeTX ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | The attestation being contested
  GYAssetClass ->
  -- | Profile ID of the disputer (its user NFT is spent to authorise)
  GYAssetClass ->
  -- | Where the deposit returns, on either verdict
  GYAddress ->
  -- | CIP-68 metadata fields (name, description, image) — the dispute's own statement
  MetadataFields ->
  -- | Disputer's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
openDisputeTX gyTargetAC gyOpenerProfileId depositTo metadata ownAddrs = do
  ctx <- ask
  let mpGY = getMintingPolicyFromCtx ctx
      mpRef = getMintingPolicyRef ctx

  -- A dispute against an attestation that does not exist is a deposit locked against nothing, and
  -- @Md4@ checks only the currency symbol — of the target AND, since the first audit of this
  -- handler, of the opener.
  _targetDatumAndValue <- getAttestationDatumAndValue gyTargetAC
  let plutusTargetAC = assetClassToPlutus gyTargetAC
  openDisputes <- getOpenDisputesForAttestation plutusTargetAC
  unless (null openDisputes) $
    throwError (GYApplicationException DisputeAlreadyOpen)

  (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionDispute
  let minLv = OnchainTypes.opMinUTxOValue oracleParams
      -- Read from the oracle here and then RECORDED in the dispute's own datum: resolution reads the
      -- recorded amount, never this one. See 'OnchainTypes.opDisputeDeposit'.
      deposit = OnchainTypes.opDisputeDeposit oracleParams

  -- @Md6@ bounds this to the validity interval, like every other date this protocol stores.
  now <- slotOfCurrentBlock
  openedAt <- pPOSIXTimeFromGYSlot now

  -- Get a seed TxOutRef for uniqueness
  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
  let seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef

  spendsOpenerUserNFT <- spendUserNFTForProfile gyOpenerProfileId ownAddrs

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Dispute NFT + deposit locked at disputesValidator
  let disputeOutputIdx = 0 :: Integer

  let plutusDepositTo = addressToPlutus depositTo
  let gyRedeemer =
        redeemerFromPlutusData
          ( OpenDispute
              seedTxOutRefPlutus
              plutusTargetAC
              (assetClassToPlutus gyOpenerProfileId)
              plutusDepositTo
              metadata
              openedAt
              disputeOutputIdx
          )

  (gyDisputeRefAC, _gyDisputeUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingDisputeNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyDisputeRefAC

  let disputeInfo =
        OnchainTypes.OnchainDispute
          { OnchainTypes.disputeId = assetClassToPlutus gyDisputeRefAC,
            OnchainTypes.disputeTarget = plutusTargetAC,
            OnchainTypes.disputeOpenedBy = assetClassToPlutus gyOpenerProfileId,
            OnchainTypes.disputeOpenedAt = openedAt,
            OnchainTypes.disputeDeposit = deposit,
            OnchainTypes.disputeDepositTo = plutusDepositTo,
            -- The token, not the whole params: it is all the Disputes validator needs to tell which
            -- reference input IS the oracle, and a datum is paid for in min-ADA.
            OnchainTypes.disputeOracleToken = OnchainTypes.oracleToken (getProtocolParamsFromCtx ctx),
            OnchainTypes.disputeVerdict = Nothing
          }
  let disputeDatum = mkCIP68Datum disputeInfo metadata []

  -- Output 0: Dispute NFT + deposit. The deposit is part of the LOCKED value, which is the whole
  -- economic mechanism: it sits in the dispute's own UTxO until a verdict releases it.
  isLockingDispute <-
    txMustLockStateWithInlineDatumAndValue
      disputesValidatorGY
      disputeDatum
      (valueSingleton gyDisputeRefAC 1 <> valueFromLovelace (minLv + deposit))

  return
    ( mconcat
        [ isSpendingSeedUTxO, -- Input (no output index)
          spendsOpenerUserNFT, -- Input (no output index)
          isValidForSafeEra, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingDisputeNFT, -- Mint (no output index)
          isLockingDispute, -- Output 0: Dispute NFT + deposit
          feeSkeleton -- (always empty: feeFor MintActionDispute is 0 by design)
        ],
      gyDisputeRefAC
    )

-- | Write a verdict onto an open dispute and return the deposit.
--
-- Corresponds to 'DisputesValidator.ResolveDispute' spending (no minting). The oracle admin signs
-- (@D1@), the verdict is written once (@D3@), and __the deposit comes back on either verdict__
-- (@D4@) — losing a dispute costs network fees and nothing else, which is why 'OnchainTypes.Verdict'
-- has exactly two constructors and no punitive third.
--
-- The deposit paid is the amount __recorded in the dispute's own datum__ and never
-- 'OnchainTypes.opDisputeDeposit' from the oracle: reading the oracle here would let the admin lower
-- the price, resolve, and keep the difference — or raise it and make an open dispute unresolvable.
--
-- __A PAUSED PROTOCOL NOW REFUSES THIS ON CHAIN, and this comment used to say the opposite.__ It
-- read: "This path deliberately does not go through 'getOracleRefInputSkeleton', so a paused
-- protocol does not block it: 'updateOracleTX' bypasses the pause for the same reason. The pause is
-- the admin's lever, and a lever that disables the admin is not one."
--
-- The last sentence is still true of 'updateOracleTX' and was never true of this function. @opPaused@
-- used to be read only by the minting policy, so a pause stopped new mints and left acceptance,
-- profile updates and dispute resolution running — which is not an emergency stop. @D7@ closed that,
-- and resolution is a protocol write like any other: an admin who needs it available unpauses first.
-- The admin is not locked out, because 'updateOracleTX' genuinely does bypass the pause, so
-- pause -> unpause -> resolve works.
--
-- __What is still wrong here, and is a real defect rather than a decision:__ this builder does not
-- consult the oracle, so while paused it hands back a transaction the chain then refuses as a script
-- failure (@D7@) instead of refusing it at build time with a @503 ProtocolPaused@ the way every other
-- write path does. Routing it through 'getOracleRefInputSkeleton' is the fix; it is not done here
-- because that function also attaches the oracle as a reference input, which this skeleton already
-- does for @D1@, and doing it twice needs a careful look at the resulting input set.
--
-- Output index layout:
--   Output 0: Resolved dispute, less the deposit, back at disputesValidator
--   Output 1: The deposit, to the address the disputer named when opening
resolveDisputeTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Dispute NFT AC
  GYAssetClass ->
  OnchainTypes.Verdict ->
  m (GYTxSkeleton 'PlutusV3)
resolveDisputeTX gyDisputeAC verdict = do
  dvRef <- asks getDisputesValidatorRef

  (disputeDatum, plutusDisputeValue) <- getDisputeDatumAndValue gyDisputeAC
  let dispute = extra disputeDatum
  -- The 400 the chain's @D3@ also refuses. Without it the build succeeds and the transaction fails
  -- as a script error, which reads like a protocol bug rather than a bad request.
  when (isJust (OnchainTypes.disputeVerdict dispute)) $
    throwError (GYApplicationException DisputeAlreadyResolved)

  (oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  gyAdminPkh <- pubKeyHashFromPlutus' (OnchainTypes.opAdminPkh oracleParams)

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Resolved dispute
  -- Output 1: Returned deposit
  let disputeOutputIdx = 0 :: Integer

  let gyRedeemer = redeemerFromPlutusData (DisputesValidator.ResolveDispute verdict disputeOutputIdx)
  spendsDispute <- txMustSpendStateFromRefScriptWithRedeemer dvRef gyDisputeAC gyRedeemer disputesValidatorGY

  gyDisputeValue <- valueFromPlutus' plutusDisputeValue
  gyDepositTo <- addressFromPlutus' (OnchainTypes.disputeDepositTo dispute)
  let depositValue = valueFromLovelace (OnchainTypes.disputeDeposit dispute)
  -- Computed with 'OnchainTypes.resolveDispute', the same function the validator computes its
  -- expected output datum with, so the two cannot disagree about what resolving does.
  let resolvedDatum = disputeDatum {extra = OnchainTypes.resolveDispute verdict dispute}

  -- Output 0: Resolved dispute, less the deposit
  isLockingResolvedDispute <-
    txMustLockStateWithInlineDatumAndValue
      disputesValidatorGY
      resolvedDatum
      (gyDisputeValue `valueMinus` depositValue)

  -- Output 1: The deposit, back to the disputer
  isReturningDeposit <- txMustPayValueToAddress gyDepositTo depositValue

  return $
    mconcat
      [ spendsDispute, -- Input (no output index)
        mustHaveRefInput oracleRef, -- Reference input: oracle UTxO (D1 reads the admin from it)
        isLockingResolvedDispute, -- Output 0: Resolved dispute
        isReturningDeposit, -- Output 1: Returned deposit
        mustBeSignedBy gyAdminPkh -- Required signer (no output index)
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

  -- A ROTATION NEEDS BOTH SIGNATURES, and the on-chain check (O5) is what makes this mandatory
  -- rather than polite. The outgoing admin consents by spending; the incoming one consents by
  -- signing, which is also the only proof the new key exists and somebody holds it. Without it a
  -- mistyped rotation ends the protocol: O1 then refuses every later update, including the one that
  -- would undo the mistake, and every open dispute becomes unresolvable because D1 wants that
  -- signature too.
  --
  -- The signing itself is the caller's problem — `admin rotate-admin` has to be run with both keys
  -- available, which is the right friction for a handover.
  let requireIncomingAdminSig = case adminAction of
        RotateAdminAction newAdmin -> mustBeSignedBy newAdmin
        _ -> mempty

  return $ mconcat [spendOracle, lockOracle, requireAdminSig, requireIncomingAdminSig]

-- | Map off-chain admin action to on-chain OracleAdminAction (for the redeemer).
adminActionToOracleAdminAction :: AdminActionType -> OracleAdminAction
adminActionToOracleAdminAction PauseProtocolAction = OraclePause
adminActionToOracleAdminAction UnpauseProtocolAction = OracleUnpause
adminActionToOracleAdminAction (SetFeesAction mFeeConfig) = OracleSetFees mFeeConfig
adminActionToOracleAdminAction (SetMinUTxOValueAction lovelace) = OracleSetMinUTxOValue lovelace
adminActionToOracleAdminAction (RotateAdminAction newAdmin) = OracleSetAdmin (pubKeyHashToPlutus newAdmin)
adminActionToOracleAdminAction (SetDisputeDepositAction lovelace) = OracleSetDisputeDeposit lovelace

-- | Apply an admin action delta to current oracle params to produce new params.
-- Must stay in sync with on-chain 'Onchain.Protocol.Types.applyOracleAdminAction'.
applyAdminAction :: AdminActionType -> OnchainTypes.OracleParams -> OnchainTypes.OracleParams
applyAdminAction PauseProtocolAction params = params {OnchainTypes.opPaused = True}
applyAdminAction UnpauseProtocolAction params = params {OnchainTypes.opPaused = False}
applyAdminAction (SetFeesAction mFeeConfig) params = params {OnchainTypes.opFeeConfig = mFeeConfig}
applyAdminAction (SetMinUTxOValueAction lovelace) params = params {OnchainTypes.opMinUTxOValue = lovelace}
applyAdminAction (RotateAdminAction newAdmin) params = params {OnchainTypes.opAdminPkh = pubKeyHashToPlutus newAdmin}
applyAdminAction (SetDisputeDepositAction lovelace) params = params {OnchainTypes.opDisputeDeposit = lovelace}

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
        dustSpendsForValidatorSkeleton getAttestationsValidatorRef attestationsValidatorGY (redeemerFromPlutusData Cleanup),
        dustSpendsForValidatorSkeleton getDisputesValidatorRef disputesValidatorGY (redeemerFromPlutusData DisputesValidator.Cleanup)
      ]
  let allSpends = concat configs
      dustCount = sum (map length configs)
  when (dustCount == 0) $
    throwError (GYApplicationException NoDustFound)
  return (mconcat allSpends, dustCount)
