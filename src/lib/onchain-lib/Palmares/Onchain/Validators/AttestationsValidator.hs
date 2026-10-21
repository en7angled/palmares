{-# LANGUAGE MultiParamTypeClasses #-}
-- Required for `makeLift`:
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:remove-trace #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:optimize #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.1.0 #-}

{-# HLINT ignore "Use &&" #-}

-- | Attestations validator enforcing attestation acceptance and permissionless cleanup.
module Palmares.Onchain.Validators.AttestationsValidator
  ( -- * Attestations Redeemer
    AttestationsRedeemer (..),

    -- * Attestations Validator
    attestationsLambda,

    -- * Compilation
    attestationsCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.CIP68
import Palmares.Onchain.Protocol
import Palmares.Onchain.Utils qualified as Utils
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V3
import PlutusLedgerApi.V3.Contexts (valueSpent)
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Attestations Redeemer

-------------------------------------------------------------------------------

-- This validator is simplified because the issuance rules live in the minting policy
-- at mint time in the MintingPolicy.

data AttestationsRedeemer
  = -- | AcceptAttestation attestationOutputIdx
    AcceptAttestation Integer
  | Cleanup
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''AttestationsRedeemer [('AcceptAttestation, 0), ('Cleanup, 1)]

type AttestationsDatum = CIP68Datum OnchainAttestation

-------------------------------------------------------------------------------

{-# INLINEABLE attestationsLambda #-}
attestationsLambda :: ScriptContext -> Bool
attestationsLambda (ScriptContext txInfo@TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  let !redeemer = unsafeFromBuiltinData @AttestationsRedeemer bredeemer
   in case scriptInfo of
        (SpendingScript spendingTxOutRef mdatum) -> case redeemer of
          -- Permissionless cleanup: allow spending if datum is absent or unparseable.
          Cleanup -> case mdatum of
            Nothing -> True
            Just (Datum bd) -> case fromBuiltinData @AttestationsDatum bd of
              Nothing -> True
              Just _ -> traceError "A0" -- Cannot cleanup valid datum (A0)
          AcceptAttestation outputIdx -> case mdatum of
            Nothing -> traceError "A0" -- No datum (A0)
            Just (Datum bdatum) -> case fromBuiltinData bdatum of
              Nothing -> traceError "A0" -- Invalid datum (A0)
              Just (attestationDatum :: AttestationsDatum) ->
                let attestation = extra attestationDatum
                    ownInput = Utils.unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs
                    ownValue = txOutValue ownInput
                    ownAddress = txOutAddress ownInput
                    updatedAttestationDatum = attestationDatum {extra = attestation {attestationIsAccepted = True}}
                    subjectUserAC = deriveUserFromRefAC (attestationSubject attestation)
                 in traceIfFalse
                      "A1"
                      $ and
                        [ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress
                            outputIdx
                            updatedAttestationDatum
                            ownValue
                            ownAddress
                            txInfoOutputs, -- Lock attestation; >= ownValue (balancer may add min-ADA)
                          V1.assetClassValueOf
                            (valueSpent txInfo)
                            subjectUserAC
                            == 1, -- Must spend the subject's user NFT
                          V1.assetClassValueOf ownValue (attestationId attestation) == 1 -- Own attestation NFT
                        ]
        _ -> traceError "A2" -- Invalid script info (A2)

-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types
{-# INLINEABLE attestationsUntyped #-}
attestationsUntyped :: BuiltinData -> BuiltinUnit
attestationsUntyped = Utils.mkUntypedLambda attestationsLambda

-- | Compile the untyped lambda to a UPLC script and splice back to Haskell.
attestationsCompile :: CompiledCode (BuiltinData -> BuiltinUnit)
attestationsCompile = $$(compile [||attestationsUntyped||])
