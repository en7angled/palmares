
-- Required for `makeLift`:
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:conservative-optimisation #-}

{-# HLINT ignore "Use &&" #-}

-- | Minting policy for the Palmares attestation protocol.
-- Controls token creation for profiles and attestations.
module Palmares.Onchain.Validators.MintingPolicy
  ( -- * Minting Redeemer
    MintingRedeemer (..),

    -- * Minting Policy
    mintingPolicyLambda,

    -- * Compilation
    mintingPolicyCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.CIP68 (MetadataFields, deriveUserFromRefAC, generateRefAndUserTN, mkCIP68Datum, validateMetadataFields)
import Palmares.Onchain.Protocol.Lookup (checkFee, readOracleParams)
import Palmares.Onchain.Protocol.Types
  ( MintAction (MintActionAttestation, MintActionProfile),
    OnchainAttestation
      ( OnchainAttestation,
        attestationIssuer,
        attestationSubject,
        attestationDate,
        attestationId,
        attestationIsAccepted
      ),
    OnchainProfile
      ( OnchainProfile,
        profileCredential,
        profileId,
        profileKind,
        protocolParams
      ),
    OnchainProfileKind,
    OracleParams (opMinUTxOValue, opPaused),
    ProfileId,
    ProtocolParams
      ( attestationsValidatorScriptHash,
        oracleToken,
        profilesValidatorScriptHash
      ),
  )
import Palmares.Onchain.Utils (hasCurrencySymbol)
import Palmares.Onchain.Utils qualified as Utils
  ( checkCredentialControl,
    checkTxOutAtIndexWithDatumMinValueAndAddress,
    inputsSpendTxOutRef,
    mkUntypedLambda,
    nameFromTxOutRef,
  )
import PlutusCore.Builtin.Debug (plcVersion110)
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Interval (before)
import PlutusLedgerApi.V3
import PlutusLedgerApi.V3.Contexts
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Minting Redeemer

-------------------------------------------------------------------------------

-- | Custom redeemer :
-- Output indices are passed in the redeemer for efficient O(1) lookup instead of O(n) search.
data MintingRedeemer
  = -- | NewAttestation seedTxOutRef metadata222 otherMetadata subject issuer attestationDate attestationOutputIdx
    NewAttestation TxOutRef MetadataFields [(BuiltinByteString, BuiltinByteString)] ProfileId ProfileId POSIXTime Integer
  | -- | MintProfile seedTxOutRef kind claimedCredential metadata profileOutputIdx
    --
    -- The claim. @claimedCredential@ is 'Nothing' for a profile that corresponds to no on-chain
    -- credential (a Community, an Auditor) and 'Just' for one that claims control of a DRep id, a
    -- committee cold credential or a stake credential — the same rule for all three, because all
    -- three are a 'Credential'.
    MintProfile TxOutRef OnchainProfileKind (Maybe Credential) MetadataFields Integer
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

-- The stable-index discipline binds from the first deployment. Nothing is deployed yet, so the
-- surviving redeemer takes index 0 rather than keeping its Belt System index and reserving holes;
-- MintProfile is APPENDED at 1 rather than inserted, which is the discipline from here on.
makeIsDataSchemaIndexed ''MintingRedeemer [('NewAttestation, 0), ('MintProfile, 1)]

-------------------------------------------------------------------------------

-- | Precomputed minLv and validator addresses for the minting policy.
data MintingContext = MintingContext
  { ctxMinLv :: Value,
    ctxProfilesAddress :: Address,
    ctxAttestationsAddress :: Address
  }

-------------------------------------------------------------------------------

-- * Minting Policy

-------------------------------------------------------------------------------

{-# INLINEABLE mintingPolicyLambda #-}
mintingPolicyLambda :: ProtocolParams -> ScriptContext -> Bool
mintingPolicyLambda protocolParams (ScriptContext txInfo@TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  let !redeemer = unsafeFromBuiltinData @MintingRedeemer bredeemer
   in case scriptInfo of
        (MintingScript mintingPolicyCurrencySymbol) ->
          let oracle = readOracleParams (oracleToken protocolParams) txInfoReferenceInputs
              !minLv = V1.lovelaceValue (V1.Lovelace (opMinUTxOValue oracle))
              !profilesValidatorAddress = V1.scriptHashAddress (profilesValidatorScriptHash protocolParams)
              !attestationsValidatorAddress = V1.scriptHashAddress (attestationsValidatorScriptHash protocolParams)
              ctx =
                MintingContext
                  { ctxMinLv = minLv,
                    ctxProfilesAddress = profilesValidatorAddress,
                    ctxAttestationsAddress = attestationsValidatorAddress
                  }
           in -- Global gate: protocol must not be paused (M0).
              traceIfFalse "M0" (not (opPaused oracle)) -- Protocol is paused (M0)
                && case redeemer of
                  NewAttestation seedTxOutRef metadata otherMetadata subject issuer attestationDate attestationOutputIdx ->
                    checkFee oracle MintActionAttestation txInfoOutputs
                      && handleNewAttestation txInfo mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadata subject issuer attestationDate attestationOutputIdx
                  MintProfile seedTxOutRef kind claimedCredential metadata profileOutputIdx ->
                    checkFee oracle MintActionProfile txInfoOutputs
                      && handleMintProfile txInfo mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef kind claimedCredential metadata profileOutputIdx
        _ -> traceError "M1" -- Invalid purpose (M1)

-------------------------------------------------------------------------------

-- * Per-Redeemer Handlers

-------------------------------------------------------------------------------

{-# INLINEABLE handleNewAttestation #-}
handleNewAttestation ::
  TxInfo ->
  CurrencySymbol ->
  MintingContext ->
  TxOutRef ->
  MetadataFields ->
  [(BuiltinByteString, BuiltinByteString)] ->
  ProfileId ->
  ProfileId ->
  POSIXTime ->
  Integer ->
  Bool
handleNewAttestation txInfo@TxInfo {..} mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadataEncoded subject issuer attestationDate attestationOutputIdx =
  let isSubjectValid = hasCurrencySymbol subject mintingPolicyCurrencySymbol
      isIssuerValid = hasCurrencySymbol issuer mintingPolicyCurrencySymbol
      minLv = ctxMinLv ctx
      attestationsValidatorAddress = ctxAttestationsAddress ctx

      (attestationRefTN, _) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      attestationRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, attestationRefTN)
      attestationNFT = V1.assetClassValue attestationRefAssetClass 1
      attestationValue = (attestationNFT + minLv)
      attestationInfo =
        OnchainAttestation
          { attestationId = attestationRefAssetClass,
            attestationSubject = subject,
            attestationIssuer = issuer,
            attestationDate = attestationDate,
            attestationIsAccepted = False
          }

      attestationDatum = mkCIP68Datum attestationInfo metadata otherMetadataEncoded
   in traceIfFalse "Ml" (attestationDate `before` txInfoValidRange) -- Attestation date before validity (Ml)
        && traceIfFalse "Mm" (validateMetadataFields metadata) -- Metadata fields validation failed (Mm)
        && traceIfFalse "Mf" (V1.assetClassValueOf (valueSpent txInfo) (deriveUserFromRefAC issuer) == 1) -- Must spend issued by user NFT (Mf)
        && traceIfFalse "Mg" (isSubjectValid && isIssuerValid) -- Profiles must have correct currency symbol (Mg)
        && traceIfFalse "Mh" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Mh)
        && traceIfFalse
          "Mj" -- Tx must mint JUST attestation NFT (Mj)
          (mintValueMinted txInfoMint == attestationNFT && mintValueBurned txInfoMint == mempty)
        && traceIfFalse "Mk" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress attestationOutputIdx attestationDatum attestationValue attestationsValidatorAddress txInfoOutputs) -- Lock attestation at AttestationsValidator address (Mk)

{-# INLINEABLE handleMintProfile #-}
handleMintProfile ::
  TxInfo ->
  CurrencySymbol ->
  ProtocolParams ->
  MintingContext ->
  TxOutRef ->
  OnchainProfileKind ->
  Maybe Credential ->
  MetadataFields ->
  Integer ->
  Bool
handleMintProfile TxInfo {..} mintingPolicyCurrencySymbol protocolParams ctx seedTxOutRef kind claimedCredential metadata profileOutputIdx =
  let minLv = ctxMinLv ctx
      profilesValidatorAddress = ctxProfilesAddress ctx

      (profileRefTN, profileUserTN) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      profileRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, profileRefTN)
      profileUserAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, profileUserTN)
      profileRefNFT = V1.assetClassValue profileRefAssetClass 1
      profileUserNFT = V1.assetClassValue profileUserAssetClass 1
      profileValue = profileRefNFT + minLv

      profileInfo =
        OnchainProfile
          { profileId = profileRefAssetClass,
            profileKind = kind,
            profileCredential = claimedCredential,
            protocolParams = protocolParams
          }
      profileDatum = mkCIP68Datum profileInfo metadata []
   in traceIfFalse "Mp1" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Mp1)
        && traceIfFalse
          "Mp2" -- Tx must mint JUST the profile ref AND user NFT (Mp2)
          (mintValueMinted txInfoMint == (profileRefNFT + profileUserNFT) && mintValueBurned txInfoMint == mempty)
        && traceIfFalse "Mp3" (checkClaim claimedCredential) -- Claimed credential is not controlled by this tx (Mp3)
        && traceIfFalse "Mp4" (validateMetadataFields metadata) -- Metadata fields validation failed (Mp4)
        && traceIfFalse "Mp5" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress profileOutputIdx profileDatum profileValue profilesValidatorAddress txInfoOutputs) -- Lock profile at ProfilesValidator address (Mp5)
  where
    -- A profile that claims nothing has nothing to prove. That is not a hole: a Community or an
    -- Auditor need not correspond to any on-chain credential, and the read layer presents such a
    -- profile as @unclaimed@ rather than verified.
    checkClaim Nothing = True
    checkClaim (Just credential) = Utils.checkCredentialControl credential txInfoSignatories txInfoInputs

-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types
{-# INLINEABLE mintingPolicyUntyped #-}
mintingPolicyUntyped :: ProtocolParams -> BuiltinData -> BuiltinUnit
mintingPolicyUntyped params =
  Utils.mkUntypedLambda (mintingPolicyLambda params)

-- | Compile the untyped lambda to a UPLC script and splice back to Haskell.
mintingPolicyCompile :: ProtocolParams -> CompiledCode (BuiltinData -> BuiltinUnit)
mintingPolicyCompile params = $$(compile [||mintingPolicyUntyped||]) `unsafeApplyCode` liftCode plcVersion110 params
