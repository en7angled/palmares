
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
  ( FeeConfig (fcAttestationFee),
    OnchainAchievement
      ( OnchainAchievement,
        achievementAwardedBy,
        achievementAwardedTo,
        achievementDate,
        achievementId,
        achievementIsAccepted
      ),
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
  ( checkTxOutAtIndexWithDatumMinValueAndAddress,
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
  = -- | NewAchievement seedTxOutRef metadata222 otherMetadata awardedTo awardedBy achievementDate achievementOutputIdx
    NewAchievement TxOutRef MetadataFields [(BuiltinByteString, BuiltinByteString)] ProfileId ProfileId POSIXTime Integer
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

-- The stable-index discipline binds from the first deployment. Nothing is deployed yet, so the
-- surviving redeemer takes index 0 rather than keeping its Belt System index and reserving holes.
makeIsDataSchemaIndexed ''MintingRedeemer [('NewAchievement, 0)]

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
                  NewAchievement seedTxOutRef metadata otherMetadata awardedTo awardedBy achievementDate achievementOutputIdx ->
                    checkFee oracle fcAttestationFee txInfoOutputs
                      && handleNewAchievement txInfo mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadata awardedTo awardedBy achievementDate achievementOutputIdx
        _ -> traceError "M1" -- Invalid purpose (M1)

-------------------------------------------------------------------------------

-- * Per-Redeemer Handlers

-------------------------------------------------------------------------------

{-# INLINEABLE handleNewAchievement #-}
handleNewAchievement ::
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
handleNewAchievement txInfo@TxInfo {..} mintingPolicyCurrencySymbol ctx seedTxOutRef metadata otherMetadataEncoded awardedTo awardedBy achievementDate achievementOutputIdx =
  let isAwardedToValid = hasCurrencySymbol awardedTo mintingPolicyCurrencySymbol
      isAwardedByValid = hasCurrencySymbol awardedBy mintingPolicyCurrencySymbol
      minLv = ctxMinLv ctx
      attestationsValidatorAddress = ctxAttestationsAddress ctx

      (achievementRefTN, _) = generateRefAndUserTN (Utils.nameFromTxOutRef seedTxOutRef)
      achievementRefAssetClass = V1.AssetClass (mintingPolicyCurrencySymbol, achievementRefTN)
      achievementNFT = V1.assetClassValue achievementRefAssetClass 1
      achievementValue = (achievementNFT + minLv)
      achievementInfo =
        OnchainAchievement
          { achievementId = achievementRefAssetClass,
            achievementAwardedTo = awardedTo,
            achievementAwardedBy = awardedBy,
            achievementDate = achievementDate,
            achievementIsAccepted = False
          }

      achievementDatum = mkCIP68Datum achievementInfo metadata otherMetadataEncoded
   in traceIfFalse "Ml" (achievementDate `before` txInfoValidRange) -- Achievement date before validity (Ml)
        && traceIfFalse "Mm" (validateMetadataFields metadata) -- Metadata fields validation failed (Mm)
        && traceIfFalse "Mf" (V1.assetClassValueOf (valueSpent txInfo) (deriveUserFromRefAC awardedBy) == 1) -- Must spend awarded by user NFT (Mf)
        && traceIfFalse "Mg" (isAwardedToValid && isAwardedByValid) -- Profiles must have correct currency symbol (Mg)
        && traceIfFalse "Mh" (Utils.inputsSpendTxOutRef seedTxOutRef txInfoInputs) -- Must spend seed for uniqueness (Mh)
        && traceIfFalse
          "Mj" -- Tx must mint JUST achievement NFT (Mj)
          (mintValueMinted txInfoMint == achievementNFT && mintValueBurned txInfoMint == mempty)
        && traceIfFalse "Mk" (Utils.checkTxOutAtIndexWithDatumMinValueAndAddress achievementOutputIdx achievementDatum achievementValue attestationsValidatorAddress txInfoOutputs) -- Lock achievement at AttestationsValidator address (Mk)

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
