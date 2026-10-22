{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use &&" #-}
{-# HLINT ignore "Use newtype instead of data" #-}

-- | Oracle validator for the Palmares attestation protocol.
-- Holds mutable operational parameters ('OracleParams') in its datum.
-- Only the current admin (from the datum) can update the oracle.
-- The oracle UTxO must be returned to the same address with AT LEAST the same value (`geq`, so the
-- balancer may add min-ADA),
-- ensuring the NFT remains locked and the oracle remains available.
module Palmares.Onchain.Validators.OracleValidator
  ( -- * Redeemer
    OracleRedeemer (..),

    -- * Validator
    oracleLambda,

    -- * Compilation
    oracleCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.Protocol.Types
  ( OracleAdminAction (OracleSetAdmin),
    OracleParams (..),
    applyOracleAdminAction,
    oracleParamsAreWellFormed,
  )
import Palmares.Onchain.Utils qualified as Utils
import PlutusLedgerApi.V3
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Oracle Redeemer

-------------------------------------------------------------------------------

-- | Redeemer for the oracle validator. Carries the output index where the
-- oracle UTxO must be returned and the admin action to apply (so the validator
-- can compute the expected new datum and use the same output check as other validators).
data OracleRedeemer = OracleUpdate Integer OracleAdminAction
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OracleRedeemer [('OracleUpdate, 0)]

-------------------------------------------------------------------------------

-- * Oracle Validator

-------------------------------------------------------------------------------

-- | Oracle validator logic.
-- Validates that:
--   1. The current admin (from datum) signs the transaction (@O1@)
--   2. The oracle UTxO is returned at the given output index with the datum produced by applying the
--      redeemer action to current params, at LEAST the same value (the balancer may add min-ADA) and
--      the same address (@O2@)
--   3. A handover (@OracleSetAdmin@) is also signed by the INCOMING admin (@O5@)
--   4. The resulting params are well-formed — no negative lovelace parameter (@O6@)
{-# INLINEABLE oracleLambda #-}
oracleLambda :: ScriptContext -> Bool
oracleLambda (ScriptContext TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  case scriptInfo of
    SpendingScript spendingRef (Just (Datum bdatum)) ->
      case fromBuiltinData @OracleParams bdatum of
        Nothing -> traceError "O0" -- Invalid oracle datum (O0)
        Just currentParams ->
          case fromBuiltinData @OracleRedeemer bredeemer of
            Nothing -> traceError "O4" -- Invalid oracle redeemer (O4)
            Just (OracleUpdate oracleOutputIdx action) ->
              let !ownInput = Utils.unsafeFindOwnInputByTxOutRef spendingRef txInfoInputs
                  !ownValue = txOutValue ownInput
                  !ownAddr = txOutAddress ownInput
                  !newParams = applyOracleAdminAction action currentParams
               in and
                    [ traceIfFalse "O1" $ elem (opAdminPkh currentParams) txInfoSignatories, -- Must be signed by admin (O1)
                      traceIfFalse "O2" $ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress oracleOutputIdx newParams ownValue ownAddr txInfoOutputs, -- Must return oracle UTxO at index (O2); >= ownValue (balancer may add min-ADA)
                      traceIfFalse "O5" $ incomingAdminSigned action, -- Handover must be signed by the INCOMING admin too (O5)
                      -- A NEGATIVE LOVELACE PARAMETER WOULD MAKE EVERY MIN-VALUE CHECK IN THE
                      -- PROTOCOL VACUOUS, because `geq`'s `These a b -> a >= b` arm is satisfied by
                      -- anything when `b` is below zero. See 'oracleParamsAreWellFormed' for the
                      -- concrete drain it opens on the admin's own wallet. Checked on the RESULT, so
                      -- it covers all six actions and every future one.
                      traceIfFalse "O6" $ oracleParamsAreWellFormed newParams -- Params must be well-formed (O6)
                    ]
    _ -> traceError "O3" -- Invalid script purpose (O3)
  where
    -- A HANDOVER IS TWO-SIDED, and only the outgoing side was ever checked.
    --
    -- `O1` proves the current admin consented. Nothing proved the new key exists or that anybody
    -- holds it, so a mistyped `OracleSetAdmin` — or a malicious one — hands the oracle to a key
    -- nobody can sign with, and `O1` then refuses every future update including the one that would
    -- undo it. That is not a recoverable mistake, it is the end of the protocol: no pause, no
    -- reprice, and every open dispute becomes unresolvable because `D1` wants this signature.
    --
    -- The signature of the incoming key is the proof. It costs one list membership on the one action
    -- that needs it and nothing on the other five, and it is the standard two-sided handover.
    --
    -- 'OracleParams.opAdminPkh' documents the outgoing requirement — "a key already lost is not
    -- [recoverable], because the rotation itself needs its signature" — and says nothing about the
    -- incoming one, which is the half that was missing. Worth noticing as a habit: the sentence
    -- explaining why a rule is right is usually about the rule that IS enforced.
    incomingAdminSigned (OracleSetAdmin newAdmin) = elem newAdmin txInfoSignatories
    incomingAdminSigned _ = True

-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types.
{-# INLINEABLE oracleUntyped #-}
oracleUntyped :: BuiltinData -> BuiltinUnit
oracleUntyped = Utils.mkUntypedLambda oracleLambda

-- | Compile the oracle validator to a UPLC script.
oracleCompile :: CompiledCode (BuiltinData -> BuiltinUnit)
oracleCompile = $$(compile [||oracleUntyped||])
