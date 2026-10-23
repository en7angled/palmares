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
import Palmares.Onchain.Protocol (OnchainProfile (..), OracleParams (opPaused), readOracleParams)
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

-- __Index 2 is burnt, deliberately.__ A @RevokeCredential@ redeemer briefly lived there (D-E) and
-- ADR 0003 removed it: it cleared a credential field in place, which an audit found irreversible and
-- reachable with a weak proof. Nothing is deployed, so the index could be reused — it is not,
-- because a stable-index discipline that makes an exception the first time it is inconvenient is not
-- a discipline. A binding is now a 'Palmares.Onchain.Protocol.Types.CredentialClaim' attestation.
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
                    oracle = readOracleParams (profileOracleToken profile) txInfoReferenceInputs
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
          traceIfFalse "P5" $ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress profileOutputIdx newCip68Datum ownValue ownAddress txInfoOutputs, -- Lock updated profile (P5); >= ownValue (balancer may add min-ADA)
          -- THE UPDATE PATH REOPENED THE HOLE `Mp6` CLOSED ON THE MINT PATH — OC-03.
          --
          -- `P5` requires the output to carry AT LEAST @ownValue@ and says nothing else about it, so
          -- a holder could re-lock the profile with its own user token inside. `P3` is then satisfied
          -- by the profile's own input, because @valueSpent@ sums ALL inputs including the script
          -- one, and `P5` re-locks >= its own value so the token never leaves again. From that block
          -- on, ANYONE can spend the profile UTxO with `UpdateProfile`.
          --
          -- And it is worse than a stuck profile. The same transaction can mint `NewAttestation` with
          -- @issuer@ = that profile: `Mf` reads @valueSpent@ too, so __anyone can issue attestations
          -- in that identity for ever__. That is the "permanently world-writable identity" the `Mp6`
          -- comment describes, reached through the update path instead of the mint.
          --
          -- Only the holder can trigger it, by self-harm or by signing a front-end's transaction — so
          -- it is not a third-party attack, and it is still irreversible, because nothing in this
          -- protocol burns a user token.
          traceIfFalse "Pa" $ V1.assetClassValueOf (Utils.valueAtOutputIdx profileOutputIdx txInfoOutputs) profileUserAssetClass == 0 -- User token must not be locked with the state (Pa)
        ]

-- __@P8@ and @P9@ are gone, and their codes are not reused.__ They belonged to the D-E
-- @RevokeCredential@ arm that ADR 0003 removed. Noted here rather than silently dropped because a
-- trace code is an operator's runbook entry: an operator who sees @P8@ in an old log should be able
-- to find out that the rule no longer exists and why, instead of finding it reassigned to something
-- else.
--
-- __Which is why @Pa@ and not @P8@.__ The audit's own fix text for @OC-03@ proposed @P8@ for the rule
-- now above, written before those two were burnt. Reusing it would have put a live rule behind a code
-- that already means something else in logs from before ADR 0003 — the precise failure the paragraph
-- above exists to prevent. So the sequence continues past the burnt pair with a letter, the way
-- @Da@ does in the Disputes validator after @D9@. @Mp3@ is burnt on the same terms in the minting
-- policy, which is why its new rules are @Ms@ and @Md9@ rather than a reuse of it.

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
