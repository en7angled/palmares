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
import Palmares.Onchain.Protocol (OnchainProfile (..), OracleParams (opPaused), ProtocolParams (oracleToken), readOracleParams)
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
  | -- | Permissionless dust/griefing cleanup. Anyone can spend a UTxO at the validator address
    -- unless it is protocol state, and protocol state is a datum the UTxO's own VALUE backs: the
    -- profile Ref NFT the datum names must be in it. A datum that merely parses is not enough —
    -- see 'Utils.isUnbackedDatum' for the permanent clutter that reading bought.
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
          -- Permissionless cleanup: a UTxO here is dust unless its own VALUE backs its datum's claim
          -- to be a profile. Absent or unparseable datum, or a datum no profile Ref NFT backs, is
          -- sweepable; a datum the NFT backs is state and nobody may sweep it.
          Cleanup -> case mdatum of
            Nothing -> True
            Just (Datum bd) -> case fromBuiltinData @(CIP68Datum OnchainProfile) bd of
              Nothing -> True
              Just (CIP68Datum _metadata _version (profile :: OnchainProfile)) ->
                -- ITS OWN CODE, not `P0`. `P0` means "this UTxO's datum is not a profile", which is
                -- a malformed transaction; this means "it IS a profile and you may not sweep it",
                -- which is somebody attempting to delete live state. One code for both told an
                -- operator nothing about which had happened.
                traceIfFalse "P7" (Utils.isUnbackedDatum (profileId profile) spendingTxOutRef txInfoInputs) -- Cannot cleanup backed state (P7)
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
                    --
                    -- Read through the token in this profile's OWN datum, which is where an
                    -- unparameterised validator gets the one external fact it needs — the same route
                    -- the Disputes Validator takes through @disputeOracleToken@. The token is part of
                    -- the 'ProtocolParams' the minting policy baked into this datum at @Mp5@, and
                    -- @P2@ below is what makes the datum trustworthy: a forged profile UTxO naming an
                    -- attacker's \"oracle\" has no Ref NFT, so the most a forged oracle can do is let
                    -- @P6@ pass for a spend @P2@ then refuses. `readOracleParams` traces @K1@ when no
                    -- reference input carries the token.
                    oracle = readOracleParams (oracleToken (protocolParams profile)) txInfoReferenceInputs
                 in case redeemer of
                      (UpdateProfile newFields profileOutputIdx) ->
                        -- A PAUSE STOPS WRITES, NOT READS, and this redeemer is a write. @opPaused@
                        -- used to be read by the minting policy alone (@M0@), so a paused protocol
                        -- halted new profiles and attestations while a hand-built transaction could
                        -- still rewrite an existing profile's metadata — the off-chain builder's
                        -- @ProtocolPaused@ is a courtesy anyone bypasses by building their own. A
                        -- lever that stops issuance and not mutation is not an emergency stop.
                        --
                        -- Its own code rather than folding into @P2@, for the reason @A3@ and @D3@
                        -- have theirs: \"paused\" and \"wrong output\" are different mistakes and an
                        -- operator should be able to tell them apart.
                        --
                        -- @Cleanup@ above is deliberately NOT gated. It moves no protocol state —
                        -- after this commit it provably cannot, since a backed datum refuses the
                        -- sweep — and making housekeeping pausable would let an admin freeze the dust
                        -- sweep while the clutter accumulates.
                        traceIfFalse "P6" (not (opPaused oracle)) -- Protocol is paused (P6)
                          && handleUpdateProfile txInfo ownValue ownAddress profileRefAssetClass profileDatum newFields profileOutputIdx
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
