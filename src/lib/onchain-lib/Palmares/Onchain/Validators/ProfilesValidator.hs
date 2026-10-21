-- Required for `makeLift`:
{-# LANGUAGE MultiParamTypeClasses #-}
-- Required for `makeLift`:
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:remove-trace #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:optimize #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.1.0 #-}

{-# HLINT ignore "Use &&" #-}

-- | Profiles validator governing profile lifecycle, image updates,
-- and nothing else.
module Palmares.Onchain.Validators.ProfilesValidator
  ( -- * Profiles Redeemer
    ProfilesRedeemer (..),
    ProfilesDatum,

    -- * Profiles Validator
    profilesLambda,

    -- * Compilation
    profilesCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.CIP68 (CIP68Datum (CIP68Datum), MetadataFields (..), deriveUserFromRefAC, updateCIP68DatumMetadata, validateMetadataFields)
import Palmares.Onchain.Protocol (OnchainProfile (..))
import Palmares.Onchain.Protocol qualified as Onchain
import Palmares.Onchain.Utils qualified as Utils
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V3
import PlutusLedgerApi.V3.Contexts
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Profiles Redeemer

-------------------------------------------------------------------------------

-- | Custom redeemer :
-- NOTE: Profile deletion is intentionally not supported to preserve lineage integrity.
-- An attestation record is a permanent historical fact and must stay resolvable.
-- Output indices are passed in the redeemer for efficient O(1) lookup instead of O(n) search.
data ProfilesRedeemer
  = -- | UpdateProfile newMetadataFields profileOutputIdx
    UpdateProfile MetadataFields Integer
  | -- | Permissionless dust/griefing cleanup. Anyone can spend a UTxO at the
    -- validator address if its datum is absent or does not parse as a valid
    -- protocol datum. Legitimate protocol UTxOs (with valid datums) are rejected.
    Cleanup
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''ProfilesRedeemer [('UpdateProfile, 0), ('Cleanup, 1)]

type ProfilesDatum = CIP68Datum Onchain.OnchainProfile

-------------------------------------------------------------------------------

-- * Profiles Validator

-------------------------------------------------------------------------------

{-# INLINEABLE profilesLambda #-}
profilesLambda :: ScriptContext -> Bool
profilesLambda (ScriptContext txInfo@TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  let redeemer = unsafeFromBuiltinData @ProfilesRedeemer bredeemer
   in case scriptInfo of
        (SpendingScript spendingTxOutRef mdatum) -> case redeemer of
          -- Permissionless cleanup: allow spending if datum is absent or unparseable.
          Cleanup -> case mdatum of
            Nothing -> True
            Just (Datum bd) -> case fromBuiltinData @(CIP68Datum OnchainProfile) bd of
              Nothing -> True
              Just _ -> traceError "P0" -- Cannot cleanup valid datum (P0)
          _ -> case mdatum of
            Nothing -> traceError "P0" -- No datum (P0)
            Just (Datum bdatum) -> case fromBuiltinData bdatum of
              Nothing -> traceError "P0" -- Invalid datum (P0)
              Just profileDatum@(CIP68Datum _metadata _version (profile :: OnchainProfile)) ->
                let !ownInput = Utils.unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs
                    !ownValue = txOutValue ownInput
                    !ownAddress = txOutAddress ownInput
                    !profileRefAssetClass = profileId profile --  as in datum.
                    -- It is important to validate that the value of this UTxO contains an NFT of this asset class.
                 in case redeemer of
                      (UpdateProfile newFields profileOutputIdx) ->
                        handleUpdateProfile txInfo ownValue ownAddress profileRefAssetClass profileDatum newFields profileOutputIdx
        _ -> traceError "P1" -- Invalid purpose (P1)

-------------------------------------------------------------------------------

-- * Per-Redeemer Handlers

-------------------------------------------------------------------------------

{-# INLINEABLE handleUpdateProfile #-}
handleUpdateProfile ::
  TxInfo ->
  Value ->
  Address ->
  V1.AssetClass ->
  CIP68Datum OnchainProfile ->
  MetadataFields ->
  Integer ->
  Bool
handleUpdateProfile txInfo@TxInfo {..} ownValue ownAddress profileRefAssetClass profileDatum newFields profileOutputIdx =
  let newCip68Datum = updateCIP68DatumMetadata newFields profileDatum
      profileUserAssetClass = deriveUserFromRefAC profileRefAssetClass
   in and
        [ traceIfFalse "P2" $ V1.assetClassValueOf ownValue profileRefAssetClass == 1, -- Own value has Ref NFT (P2)
          traceIfFalse "P3" $ V1.assetClassValueOf (valueSpent txInfo) profileUserAssetClass == 1, -- Must spend User NFT (P3)
          traceIfFalse "P4" $ validateMetadataFields newFields, -- Metadata fields validation failed (P4)
          traceIfFalse "P5" $ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress profileOutputIdx newCip68Datum ownValue ownAddress txInfoOutputs -- Lock updated profile (P5); >= ownValue (balancer may add min-ADA)
        ]


-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types
{-# INLINEABLE profilesUntyped #-}
profilesUntyped :: BuiltinData -> BuiltinUnit
profilesUntyped = Utils.mkUntypedLambda profilesLambda

-- | Compile the untyped lambda to a UPLC script and splice back to Haskell.
profilesCompile :: CompiledCode (BuiltinData -> BuiltinUnit)
profilesCompile = $$(compile [||profilesUntyped||])
