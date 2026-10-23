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
  ( OracleAdminAction (OracleSetAdmin, OracleSetArbiter),
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
--   1. The current admin (from datum) proves control of its credential (@O1@)
--   2. The oracle UTxO is returned at the given output index with the datum produced by applying the
--      redeemer action to current params, at LEAST the same value (the balancer may add min-ADA) and
--      the same address (@O2@)
--   3. A handover (@OracleSetAdmin@ or @OracleSetArbiter@) is also proved by the INCOMING side (@O5@)
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
                    [ traceIfFalse "O1" $ Utils.checkCredentialControl (opAdmin currentParams) txInfoSignatories txInfoInputs, -- Admin must prove control (O1)
                      traceIfFalse "O2" $ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress oracleOutputIdx newParams ownValue ownAddr txInfoOutputs, -- Must return oracle UTxO at index (O2); >= ownValue (balancer may add min-ADA)
                      traceIfFalse "O5" $ incomingProvedControl action, -- Handover must be proved by the INCOMING side too (O5)
                      -- A NEGATIVE LOVELACE PARAMETER WOULD MAKE EVERY MIN-VALUE CHECK IN THE
                      -- PROTOCOL VACUOUS, because `geq`'s `These a b -> a >= b` arm is satisfied by
                      -- anything when `b` is below zero. See 'oracleParamsAreWellFormed' for the
                      -- concrete drain it opens on the admin's own wallet. Checked on the RESULT, so
                      -- it covers all seven actions and every future one.
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
    -- Proof of control by the incoming side is the check. It costs one credential test on the two
    -- actions that need it and nothing on the other six, and it is the standard two-sided handover.
    --
    -- 'OracleParams.opAdmin' documents the outgoing requirement — "one already lost is not
    -- [recoverable], because the rotation itself needs its proof" — and says nothing about the
    -- incoming one, which is the half that was missing. Worth noticing as a habit: the sentence
    -- explaining why a rule is right is usually about the rule that IS enforced.
    --
    -- __It is proof of CONTROL and no longer a signature__, because ADR 0005 made both fields a
    -- 'Credential'. The two sides of the test differ in cost and in shape: handing over to a key
    -- needs that key's signature, handing over to a native multisig needs a UTxO at the multisig's
    -- own address to be spent in this same transaction. The second has a prerequisite worth saying
    -- out loud in the runbook — __fund the incoming multisig first__ — because a script that holds
    -- no UTxO at its own address cannot prove control at all, which is the limitation
    -- 'Palmares.Onchain.Utils.checkCredentialControl' already documents for credential claims.
    --
    -- Both handovers are covered, and the arbiter's is the one that matters more: losing 'opAdmin'
    -- freezes the parameters, while losing 'opArbiter' locks every open dispute's deposit.
    incomingProvedControl (OracleSetAdmin newAdmin) = Utils.checkCredentialControl newAdmin txInfoSignatories txInfoInputs
    incomingProvedControl (OracleSetArbiter newArbiter) = Utils.checkCredentialControl newArbiter txInfoSignatories txInfoInputs
    incomingProvedControl _ = True

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
