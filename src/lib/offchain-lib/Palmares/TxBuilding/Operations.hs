-- | Transaction skeleton building: profiles, ranks, memberships, attestations, oracle admin, dust cleanup.
module Palmares.TxBuilding.Operations where

import Control.Monad (unless, when)
import Control.Monad.Reader.Class (MonadReader, ask, asks)
import Data.Maybe
import Palmares.DomainTypes.Core.Actions (AdminActionType (..), ClaimWitness (..))
import GHC.Stack (HasCallStack)
import GeniusYield.TxBuilder
import GeniusYield.Types
import GeniusYield.Types.Script.ScriptHash (scriptHashFromPlutus)
import Palmares.Onchain.CIP68 (CIP68Datum (..), ImageURI, MetadataFields (..), extra, getMetadataFields, mkCIP68Datum, updateCIP68DatumMetadata)
import Palmares.Onchain.Protocol.Types (OracleAdminAction (OraclePause, OracleSetAdmin, OracleSetArbiter, OracleSetDisputeDeposit, OracleSetDisputeTimeout, OracleSetFees, OracleSetMinUTxOValue, OracleUnpause))
import Palmares.Onchain.Protocol.Lookup qualified as Lookup
import Palmares.Onchain.Protocol.Types qualified as OnchainTypes
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer (..))
import Palmares.Onchain.Validators.DisputesValidator qualified as DisputesValidator (DisputesRedeemer (Cleanup, ExpireDispute, ResolveDispute))
import Palmares.Onchain.Validators.MintingPolicy
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer (OracleUpdate))
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer (UpdateProfile))
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (ProfilesRedeemer (Cleanup))
import PlutusLedgerApi.V3
import Palmares.TxBuilding.Context (DeployedScriptsContext (..), getAttestationsValidatorRef, getDisputesValidatorRef, getMintingPolicyFromCtx, getMintingPolicyRef, getOracleValidatorRef, getProfilesValidatorRef, getProtocolParamsFromCtx)
import Palmares.TxBuilding.Conversions (cip68StandardMetadataKeys, claimWitnessToTxInWitness)
import Palmares.TxBuilding.Exceptions (TxBuildingException (..))
-- getUTxOWithTokenAtAddresses dropped with `hasUserNFTAt`, its only caller in this module. The
-- function itself stays: `Skeletons.txMustSpendFromAddress` calls it, and `Lookups.queryOracleParams`
-- calls it internally.
import Palmares.TxBuilding.Lookups
  (
    getUTxOWithTokenAtAddresses, ensureSubjectProfileExists,
    getAttestationDatumAndValue,
    getDisputeDatumAndValue,
    getDustUTxOs,
    getOpenDisputesForAttestation,
    getProfileStateDatumAndValue,
    queryOracleParams,
  )
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
spendUserNFTForProfile profileRefAC ownAddrs = fst <$> spendUserNFTForProfileAt profileRefAC ownAddrs

-- | The same, and the ADDRESS the user NFT was found at.
--
-- The address is what @OF-02@ needed: it is the one address guaranteed to be an input, because
-- spending that UTxO is how the holder authorises, so it is the only sound default for a dispute's
-- @deposit_to@ under @Md8@. Returned rather than re-looked-up, so the two cannot disagree about
-- which UTxO is meant.
spendUserNFTForProfileAt ::
  (GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  GYAssetClass ->
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAddress)
spendUserNFTForProfileAt profileRefAC ownAddrs = do
  gyUserAC <- gyDeriveUserFromRefAC profileRefAC
  tokenUtxo <- getUTxOWithTokenAtAddresses gyUserAC ownAddrs ProfileNotFound
  return
    ( mustHaveInput (GYTxIn (utxoRef tokenUtxo) GYTxInWitnessKey),
      utxoAddress tokenUtxo
    )

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
--     required signer and @Mc3@ finds it in @txInfoSignatories@;
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

-- | Mint a profile. It claims no credential — ADR 0003 made a binding its own record, built by
-- 'credentialAttestationTX'.
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
  -- | CIP-68 metadata fields (name, description, image)
  MetadataFields ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
claimProfileTX kind metadata = do
  ctx <- ask
  let mpGY = getMintingPolicyFromCtx ctx
      mpRef = getMintingPolicyRef ctx
  (oracleRefSkeleton, oracleParams, feeSkeleton, isValidForSafeEra) <-
    getOracleFeeAndValiditySkeleton OnchainTypes.MintActionProfile
  let minLv = OnchainTypes.opMinUTxOValue oracleParams


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

  let gyRedeemer = redeemerFromPlutusData (MintProfile seedTxOutRefPlutus kind metadata profileOutputIdx)

  (gyProfileRefAC, _gyProfileUserAC) <- gyGenerateRefAndUserAC mpGY seedTxOutRef
  isMintingProfileNFTs <- txMustMintCIP68UserAndRef mpRef mpGY gyRedeemer gyProfileRefAC

  let profileInfo =
        OnchainTypes.OnchainProfile
          { OnchainTypes.profileId = assetClassToPlutus gyProfileRefAC,
            OnchainTypes.profileKind = kind,
            -- ADR 0006: only the oracle token was ever read off a profile datum, so only it is
            -- written. The three validator hashes that used to ride along were never read from here.
            OnchainTypes.profileOracleToken = OnchainTypes.oracleToken (getProtocolParamsFromCtx ctx)
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
          -- No claim proof here any more: minting a profile claims nothing (ADR 0003). The proof
          -- moved to 'claimCredentialTX', where the transaction's whole purpose is the binding.
          isValidForSafeEra, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingProfileNFTs, -- Mint (no output index)
          isLockingProfileState, -- Output 0: Profile state
          feeSkeleton -- Output 1 (optional): Fee payment
        ],
      gyProfileRefAC
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
  -- The two credential kinds are not issuable here. This builder names no credential, so it would
  -- build a record `Mc2` refuses — and mirroring that refusal off chain is the same discipline every
  -- other rule in this module follows: without it the chain's "no" arrives as a generic build
  -- failure and the caller cannot tell a wrong route from a funding problem. A pattern match rather
  -- than `==` because 'AttestationKind' has no 'Eq' instance, deliberately.
  case kind of
    OnchainTypes.CredentialClaim -> throwError (GYApplicationException AttestationKindIsCredentialBinding)
    OnchainTypes.CredentialWithdrawal -> throwError (GYApplicationException AttestationKindIsCredentialBinding)
    _ -> pure ()
  mapM_
    ( \(k, _) ->
        when (k `elem` cip68StandardMetadataKeys) $
          throwError (GYApplicationException AttestationOtherMetadataReservedKeys)
    )
    otherMetadata
  mpGY <- asks getMintingPolicyFromCtx
  mpRef <- asks getMintingPolicyRef
  attestationProtocolParams <- asks getProtocolParamsFromCtx
  (oracleRefSkeleton, oracleParams, feeSkeleton, isInvalidBeforeNow) <- getOracleFeeAndValiditySkeleton OnchainTypes.MintActionAttestation
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  -- Review Focus item 3, off-chain half. The minting policy checks only the subject's currency
  -- symbol, and nothing in this protocol burns, so an attestation about a profile that does not exist
  -- is permanently pending AND permanently unremovable. See 'ensureSubjectProfileExists'.
  ensureSubjectProfileExists gySubjectProfileId

  -- The off-chain half of inherited fix #4, finished. @Mq@ requires the date to be CONTAINED in the
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
          -- An ORDINARY attestation names no credential, and @Mc4@ refuses one that does. The two
          -- credential kinds are built by 'credentialAttestationTX'.
          Nothing
          attestationOutputIdx
  let gyRedeemer = redeemerFromPlutusData redeemer

  -- Generate attestation NFT AC
  gyAttestationRefAC <- gyGenerateAttestationAC mpGY seedTxOutRef
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
            OnchainTypes.attestationIsAccepted = False,
            -- The same line 'openDisputeTX' writes for `disputeOracleToken`, and it has to agree
            -- with the policy's compile-time parameter exactly: `Mk` compares this whole datum
            -- against the output, so a wrong token here is a mint that does not validate.
            OnchainTypes.attestationOracleToken = OnchainTypes.oracleToken attestationProtocolParams,
            OnchainTypes.attestationCredential = Nothing
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

-- | Mint a 'CredentialClaim' or a 'CredentialWithdrawal' — the two records that bind a profile to a
-- Cardano credential and end that binding. __ADR 0003.__
--
-- __Self-issued: subject and issuer are the same profile__, which @Mc1@ requires. The two parties to
-- a binding are the profile and the credential, and a credential is not a profile — so the issuer
-- field names the profile the record is about and the authority is stated by the rules: @Mf@ for the
-- profile's own consent, @Mc3@ for the credential's.
--
-- __And on a withdrawal the profile is deliberately NOT asked.__ @Mf@ exempts that kind, because the
-- case it exists for is a profile that claimed somebody else's credential — and that profile's user
-- token is held by whoever did it. This builder therefore spends the issuer's user NFT only for a
-- claim, which is also why it refuses to build a withdrawal for a profile whose token the caller
-- happens to hold: the chain does not ask for it, so neither does this.
--
-- __Why this duplicates 'issueAttestationTX' rather than sharing a core.__ They differ in five
-- places — who the issuer is, the kind, the credential, the proof, and whether the user NFT is spent
-- — and, more to the point, a divergence between either builder and the policy is a VALIDATION
-- failure rather than a silent one: @Mk@ compares the whole datum this locks against the datum the
-- policy recomputes from the redeemer. Two readable builders whose disagreement fails loudly beat
-- one parameterised builder nobody can read.
credentialAttestationTX ::
  (HasCallStack, GYTxUserQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | 'CredentialClaim' or 'CredentialWithdrawal'; anything else is a caller error
  OnchainTypes.AttestationKind ->
  -- | The profile binding itself, or ending its binding
  GYAssetClass ->
  -- | The credential and the governance role it is claimed under — ADR 0006. A bare 'Credential'
  -- here is what threw CIP-129's header away and made every claim render as @drep1…@.
  OnchainTypes.ClaimedCredential ->
  -- | How control of a SCRIPT credential is proven; ignored for a key credential
  Maybe ClaimWitness ->
  -- | CIP-68 metadata fields for the record itself
  MetadataFields ->
  -- | The caller's addresses, to spend the profile's user NFT on a claim
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
credentialAttestationTX kind gyProfileRefAC credential mWitness metadata ownAddrs = do
  mpGY <- asks getMintingPolicyFromCtx
  mpRef <- asks getMintingPolicyRef
  attestationProtocolParams <- asks getProtocolParamsFromCtx
  (oracleRefSkeleton, oracleParams, feeSkeleton, isInvalidBeforeNow) <- getOracleFeeAndValiditySkeleton OnchainTypes.MintActionAttestation
  let minLv = OnchainTypes.opMinUTxOValue oracleParams

  -- The profile has to exist, for the reason `issueAttestationTX` gives: nothing burns, so a record
  -- about a profile that does not exist is permanent and unremovable.
  ensureSubjectProfileExists gyProfileRefAC

  -- Resolved first, so a binding that cannot be proven never reaches the balancer.
  claimProof <- claimProofSkeleton (OnchainTypes.claimedCredentialOf credential) mWitness

  -- A claim is the profile speaking too, so it spends the profile's user NFT (@Mf@). A withdrawal is
  -- the credential alone, and @Mf@ exempts it.
  spendsProfileUserNFT <- case kind of
    OnchainTypes.CredentialWithdrawal -> return mempty
    _ -> do
      gyProfileUserAC <- gyDeriveUserFromRefAC gyProfileRefAC
      txMustSpendFromAddress gyProfileUserAC ownAddrs GYTxInWitnessKey

  now <- slotOfCurrentBlock
  recordedAt <- pPOSIXTimeFromGYSlot now

  seedTxOutRef <- someUTxOWithoutRefScript
  let isSpendingSeedUTxO = mustHaveInput (GYTxIn seedTxOutRef GYTxInWitnessKey)
      seedTxOutRefPlutus = txOutRefToV3Plutus seedTxOutRef
      attestationOutputIdx = 0 :: Integer
      plutusProfileId = assetClassToPlutus gyProfileRefAC

  let gyRedeemer =
        redeemerFromPlutusData
          ( NewAttestation
              seedTxOutRefPlutus
              metadata
              []
              plutusProfileId -- subject
              plutusProfileId -- issuer, the same profile: Mc1
              kind
              recordedAt
              Nothing -- a binding claims no period; the dates that matter are the records' own
              (Just credential)
              attestationOutputIdx
          )

  gyAttestationRefAC <- gyGenerateAttestationAC mpGY seedTxOutRef
  isMintingAttestationNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyAttestationRefAC

  let attestationInfo =
        OnchainTypes.OnchainAttestation
          { OnchainTypes.attestationId = assetClassToPlutus gyAttestationRefAC,
            OnchainTypes.attestationSubject = plutusProfileId,
            OnchainTypes.attestationIssuer = plutusProfileId,
            OnchainTypes.attestationKind = kind,
            OnchainTypes.attestationDate = recordedAt,
            OnchainTypes.attestationPeriod = Nothing,
            OnchainTypes.attestationIsAccepted = False,
            OnchainTypes.attestationOracleToken = OnchainTypes.oracleToken attestationProtocolParams,
            OnchainTypes.attestationCredential = Just credential
          }
  let attestationDatum = mkCIP68Datum attestationInfo metadata []

  isLockingAttestation <-
    txMustLockStateWithInlineDatumAndValue
      attestationsValidatorGY
      attestationDatum
      (valueSingleton gyAttestationRefAC 1 <> valueFromLovelace minLv)

  return
    ( mconcat
        [ isSpendingSeedUTxO, -- Input (no output index)
          spendsProfileUserNFT, -- Input, on a claim only (no output index)
          claimProof, -- Input or required signer (no output index)
          isInvalidBeforeNow, -- Validity (no output index)
          oracleRefSkeleton, -- Reference input: oracle UTxO
          isMintingAttestationNFT, -- Mint (no output index)
          isLockingAttestation, -- Output 0: the binding record
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
  -- | Where the deposit returns, on either verdict. 'Nothing' defaults to the address holding the
  -- opener's user NFT — @OF-02@.
  --
  -- __That default is the only one that satisfies @Md8@ by construction.__ @Md8@ requires an input
  -- AT the deposit address, and the user NFT's own UTxO is already an input because spending it is
  -- how the opener authorises. The previous default was the wallet's CHANGE address, which for a
  -- multi-address wallet need not be an input at all — so the honest case failed, and it failed as
  -- \"Not enough ADA\" because the builder forced no input and the balancer was simply asked for a
  -- transaction it could not make.
  Maybe GYAddress ->
  -- | CIP-68 metadata fields (name, description, image) — the dispute's own statement
  MetadataFields ->
  -- | Disputer's wallet addresses (to spend User NFT)
  [GYAddress] ->
  m (GYTxSkeleton 'PlutusV3, GYAssetClass)
openDisputeTX gyTargetAC gyOpenerProfileId mDepositTo metadata ownAddrs = do
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

  -- The UTxO that authorises, and the address it sits at — which is the deposit default.
  (spendsOpenerUserNFT, userNFTAddr) <- spendUserNFTForProfileAt gyOpenerProfileId ownAddrs

  -- @Md8@ wants an input AT `depositTo`. For the default that is free: the user NFT's own UTxO is
  -- already that input, because spending it is how the opener authorises.
  --
  -- For a caller-named address the input has to be forced, and it may only be forced from an address
  -- the caller declared they are spending from — `ownAddrs` is `usedAddresses`, which the client
  -- supplies. An input from anywhere else needs THAT holder's signature, which this builder cannot
  -- obtain and the caller cannot supply, so forcing it would produce an unsignable transaction: a
  -- worse failure than the one @OF-02@ is about, because it would fail after the user signed.
  --
  -- __That is not stricter than the validator, and the comment in `UnitTests.Dispute` that used to
  -- say so was wrong about the mechanism.__ A cold wallet the disputer also spends from in this
  -- transaction has to appear in `usedAddresses` or the builder cannot spend from it either. So the
  -- cold-wallet case is served; what is refused is naming an address nobody in this transaction can
  -- spend, which is precisely the case the chain would reject.
  (depositTo, forcesDepositInput) <- case mDepositTo of
    Nothing -> return (userNFTAddr, mempty)
    Just named
      | named == userNFTAddr -> return (named, mempty)
      | named `notElem` ownAddrs -> throwError (GYApplicationException DepositAddressNotSpendable)
      | otherwise -> do
          candidates <- utxosToList <$> utxosAtAddress named Nothing
          case filter (isNothing . utxoRefScript) candidates of
            [] -> throwError (GYApplicationException DepositAddressNotSpendable)
            (u : _) -> return (named, mustHaveInput (GYTxIn (utxoRef u) GYTxInWitnessKey))

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

  gyDisputeRefAC <- gyGenerateDisputeAC mpGY seedTxOutRef
  isMintingDisputeNFT <- txMustMintWithMintRef True mpRef mpGY gyRedeemer gyDisputeRefAC

  let disputeInfo =
        OnchainTypes.OnchainDispute
          { OnchainTypes.disputeId = assetClassToPlutus gyDisputeRefAC,
            OnchainTypes.disputeTarget = plutusTargetAC,
            OnchainTypes.disputeOpenedBy = assetClassToPlutus gyOpenerProfileId,
            OnchainTypes.disputeOpenedAt = openedAt,
            -- Computed here and recorded, never read from the oracle at closing time: see
            -- 'OnchainTypes.disputeStaleAfter'. `Md*` compares this whole datum against the output,
            -- so this has to be the same arithmetic the minting policy does.
            OnchainTypes.disputeStaleAfter = openedAt + POSIXTime (OnchainTypes.opDisputeTimeoutMs oracleParams),
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
          forcesDepositInput, -- Input at deposit_to, for Md8 (empty when that IS the NFT's address)
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
  -- | How the arbiter proves control, when 'OnchainTypes.opArbiter' is a script. 'Nothing' for a
  -- key arbiter, whose proof is a signature — which is every deployment until somebody rotates it.
  Maybe ClaimWitness ->
  m (GYTxSkeleton 'PlutusV3)
resolveDisputeTX gyDisputeAC verdict mArbiterWitness = do
  dvRef <- asks getDisputesValidatorRef

  (disputeDatum, plutusDisputeValue) <- getDisputeDatumAndValue gyDisputeAC
  let dispute = extra disputeDatum
  -- The 400 the chain's @D3@ also refuses. Without it the build succeeds and the transaction fails
  -- as a script error, which reads like a protocol bug rather than a bad request.
  when (isJust (OnchainTypes.disputeVerdict dispute)) $
    throwError (GYApplicationException DisputeAlreadyResolved)
  -- The 400 the chain's @Da@ also refuses. `DisputeVerdict` has three constructors and only two of
  -- them are findings; `expired` is written by the clock, through `expireDisputeTX`, and never by an
  -- admin asserting it.
  when (verdict == OnchainTypes.VerdictExpired) $
    throwError (GYApplicationException DisputeVerdictNotAFinding)

  (oracleParams, oracleRef, _oracleValue) <- queryOracleParams
  -- 'opArbiter' and not 'opAdmin' — ADR 0005 split the verdict-writing power out, and @D1@ reads
  -- the field this reads. Genesis sets the two equal, so a deployment that has not split them sees
  -- no difference here.
  requireArbiterProof <- claimProofSkeleton (OnchainTypes.opArbiter oracleParams) mArbiterWitness

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
        requireArbiterProof -- Proof of control, not a bare signature (no output index)
      ]

-- | Close an undecided dispute whose deadline has passed — D-A, and the only write in this protocol
-- that needs no authority at all.
--
-- __No oracle reference input and no required signer__, because @ExpireDispute@ reads neither. That
-- is the whole design: an escape hatch the admin can gate — by pausing, or by simply holding the
-- only key — is not an escape hatch, and an admin who does not act is the failure this exit exists
-- to bound. What the transaction does carry is a validity range, which is what the chain compares
-- against the dispute's own @disputeStaleAfter@.
--
-- Two 400s before the chain sees it, for the two things @D3@ and @D9@ also refuse. Without them the
-- build succeeds and the submission dies as a script error, which reads like a protocol bug rather
-- than a bad request.
expireDisputeTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  -- | Dispute NFT AC
  GYAssetClass ->
  m (GYTxSkeleton 'PlutusV3)
expireDisputeTX gyDisputeAC = do
  dvRef <- asks getDisputesValidatorRef

  (disputeDatum, plutusDisputeValue) <- getDisputeDatumAndValue gyDisputeAC
  let dispute = extra disputeDatum
  when (isJust (OnchainTypes.disputeVerdict dispute)) $
    throwError (GYApplicationException DisputeAlreadyResolved)

  now <- slotOfCurrentBlock
  nowT <- pPOSIXTimeFromGYSlot now
  -- `<=` and not `<`: the chain's @D9@ asks for the whole validity range to sit at or after the
  -- deadline, and the range this builds STARTS at `now`, so a transaction built exactly at the
  -- deadline is valid. Refusing one built before it is the 400.
  when (nowT < OnchainTypes.disputeStaleAfter dispute) $
    throwError (GYApplicationException DisputeNotStaleYet)

  -- ============================================================
  -- Output index tracking (order must match skeleton mconcat order)
  -- ============================================================
  -- Output 0: Expired dispute
  -- Output 1: Returned deposit
  let disputeOutputIdx = 0 :: Integer
      gyRedeemer = redeemerFromPlutusData (DisputesValidator.ExpireDispute disputeOutputIdx)
  spendsDispute <- txMustSpendStateFromRefScriptWithRedeemer dvRef gyDisputeAC gyRedeemer disputesValidatorGY

  gyDisputeValue <- valueFromPlutus' plutusDisputeValue
  gyDepositTo <- addressFromPlutus' (OnchainTypes.disputeDepositTo dispute)
  let depositValue = valueFromLovelace (OnchainTypes.disputeDeposit dispute)
      -- The same function the validator computes its expected output datum with, so the two cannot
      -- disagree about what closing a dispute does — including that it changes nothing else.
      expiredDatum = disputeDatum {extra = OnchainTypes.resolveDispute OnchainTypes.VerdictExpired dispute}

  isLockingExpiredDispute <-
    txMustLockStateWithInlineDatumAndValue
      disputesValidatorGY
      expiredDatum
      (gyDisputeValue `valueMinus` depositValue)

  isReturningDeposit <- txMustPayValueToAddress gyDepositTo depositValue

  return $
    mconcat
      [ spendsDispute, -- Input (no output index)
        txIsValidForSafeEra now, -- D9 compares this range against disputeStaleAfter
        isLockingExpiredDispute, -- Output 0: Expired dispute
        isReturningDeposit -- Output 1: Returned deposit
      ]

------------------------------------------------------------------------------------------------

-- * Oracle Management Operations

------------------------------------------------------------------------------------------------

-- | Build a transaction skeleton that updates oracle parameters based on an admin action.
-- Queries the current oracle params, applies the action delta, and builds spend + re-lock skeletons.
updateOracleTX ::
  (HasCallStack, GYTxQueryMonad m, MonadReader DeployedScriptsContext m) =>
  AdminActionType ->
  -- | How the CURRENT admin proves control, when its credential is a script. 'Nothing' for a key
  -- admin, whose proof is a signature.
  Maybe ClaimWitness ->
  m (GYTxSkeleton 'PlutusV3)
updateOracleTX adminAction mAdminWitness = do
  ovRef <- asks getOracleValidatorRef
  (currentParams, oracleRef, oracleValue) <- queryOracleParams
  let actionPlutus = adminActionToOracleAdminAction adminAction
  let gyRedeemer = redeemerFromPlutusData (OracleUpdate 0 actionPlutus)

  -- Apply the action to derive the new oracle params (must match on-chain applyOracleAdminAction)
  let newParams = applyAdminAction adminAction currentParams

  -- Spend the current oracle UTxO
  let currentDatum = datumFromPlutusData currentParams
  let spendOracle = txMustSpendFromRefScriptWithKnownDatum ovRef oracleRef currentDatum gyRedeemer oracleValidatorGY

  -- Re-lock oracle with new datum and same value
  lockOracle <- txMustLockStateWithInlineDatumAndValue oracleValidatorGY newParams oracleValue

  -- O1 IS NO LONGER A SIGNATURE, it is proof of control — ADR 0005 made `opAdmin` a `Credential`.
  -- `claimProofSkeleton` is the same prover the credential claim uses, and reusing it is the point:
  -- a key admin still produces `mustBeSignedBy` and nothing about today's deployment changes, while
  -- a native-multisig admin produces a spent input at its own address, which is what the on-chain
  -- `checkCredentialControl` looks for.
  requireAdminProof <- claimProofSkeleton (OnchainTypes.opAdmin currentParams) mAdminWitness

  -- A ROTATION NEEDS BOTH SIDES, and the on-chain check (O5) is what makes this mandatory rather
  -- than polite. The outgoing side consents by spending the oracle; the incoming one consents by
  -- proving control, which is also the only evidence the new credential exists and somebody holds
  -- it. Without it a mistyped rotation ends the protocol: O1 then refuses every later update,
  -- including the one that would undo the mistake, and every open dispute becomes unresolvable
  -- because D1 wants the same kind of proof.
  --
  -- Producing that proof is the caller's problem, and for a script target it has a prerequisite the
  -- runbook has to state: the incoming multisig must already hold a UTxO at its own address, or
  -- `claimProofSkeleton` throws `ScriptCredentialHasNoUtxo` and there is nothing to spend.
  requireIncomingProof <- case adminAction of
    RotateAdminAction newAdmin mWitness -> claimProofSkeleton newAdmin mWitness
    RotateArbiterAction newArbiter mWitness -> claimProofSkeleton newArbiter mWitness
    _ -> return mempty

  return $ mconcat [spendOracle, lockOracle, requireAdminProof, requireIncomingProof]

-- | Map off-chain admin action to on-chain OracleAdminAction (for the redeemer).
adminActionToOracleAdminAction :: AdminActionType -> OracleAdminAction
adminActionToOracleAdminAction PauseProtocolAction = OraclePause
adminActionToOracleAdminAction UnpauseProtocolAction = OracleUnpause
adminActionToOracleAdminAction (SetFeesAction mFeeConfig) = OracleSetFees mFeeConfig
adminActionToOracleAdminAction (SetMinUTxOValueAction lovelace) = OracleSetMinUTxOValue lovelace
adminActionToOracleAdminAction (RotateAdminAction newAdmin _) = OracleSetAdmin newAdmin
adminActionToOracleAdminAction (SetDisputeDepositAction lovelace) = OracleSetDisputeDeposit lovelace
adminActionToOracleAdminAction (SetDisputeTimeoutAction ms) = OracleSetDisputeTimeout ms
adminActionToOracleAdminAction (RotateArbiterAction newArbiter _) = OracleSetArbiter newArbiter

-- | Apply an admin action delta to current oracle params to produce new params.
-- Must stay in sync with on-chain 'Onchain.Protocol.Types.applyOracleAdminAction'.
applyAdminAction :: AdminActionType -> OnchainTypes.OracleParams -> OnchainTypes.OracleParams
applyAdminAction PauseProtocolAction params = params {OnchainTypes.opPaused = True}
applyAdminAction UnpauseProtocolAction params = params {OnchainTypes.opPaused = False}
applyAdminAction (SetFeesAction mFeeConfig) params = params {OnchainTypes.opFeeConfig = mFeeConfig}
applyAdminAction (SetMinUTxOValueAction lovelace) params = params {OnchainTypes.opMinUTxOValue = lovelace}
applyAdminAction (RotateAdminAction newAdmin _) params = params {OnchainTypes.opAdmin = newAdmin}
applyAdminAction (SetDisputeDepositAction lovelace) params = params {OnchainTypes.opDisputeDeposit = lovelace}
applyAdminAction (SetDisputeTimeoutAction ms) params = params {OnchainTypes.opDisputeTimeoutMs = ms}
applyAdminAction (RotateArbiterAction newArbiter _) params = params {OnchainTypes.opArbiter = newArbiter}

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
