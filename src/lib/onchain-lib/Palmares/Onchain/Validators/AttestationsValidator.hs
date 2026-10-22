{-# LANGUAGE MultiParamTypeClasses #-}
-- Required for `makeLift`:
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:remove-trace #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:optimize #-}
-- {-# OPTIONS_GHC -fplugin-opt PlutusTx.Plugin:target-version=1.1.0 #-}

{-# HLINT ignore "Use &&" #-}

-- | Attestations validator enforcing attestation acceptance and permissionless cleanup.
--
-- __A LINEAGE ATTESTATION CAN NEVER BE ACCEPTED, and that is a limit of the feature rather than a
-- missing check.__ An attestation about an earlier attestation is a record the spec asks for, and
-- 'Palmares.TxBuilding.Lookups.ensureSubjectProfileExists' permits it on purpose. But @A1@ is how a
-- subject consents: the transaction must spend the user NFT derived from the subject's id, and
-- @handleNewAttestation@ mints only a __reference__ token. No user token for an attestation exists,
-- in any wallet, so no transaction can satisfy @A1@ for a lineage record. It stays
-- @attestationIsAccepted = False@ for as long as the chain exists, and nothing in this protocol
-- burns it.
--
-- Letting the subject attestation's own subject consent on its behalf would be the semantically
-- right fix and is deliberately not done: it needs that attestation as a reference input on the
-- accept path, and a validator cannot tell a profile id from an attestation id — both are CIP-67
-- reference tokens of the same policy — so it would cost a reference input on EVERY acceptance to
-- serve a case that has no users yet. @UnitTests.Attestation@ 5.11b pins the limit so it cannot be
-- rediscovered as a bug.
--
-- What the limit actually requires is a READ-LAYER distinction. An @Endorsement@ of a record is its
-- issuer's statement and stands on the issuer alone; presenting it as "pending", which is what
-- @isAccepted = False@ means on a normal attestation, is the real defect and belongs to the read
-- surface.
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
          -- Permissionless cleanup: a UTxO here is dust unless its own VALUE backs its datum's claim
          -- to be an attestation. Absent or unparseable datum, or a datum no attestation NFT backs,
          -- is sweepable; a datum the NFT backs is state and nobody may sweep it. The attestation
          -- path is the one where this matters most: a record is permanent and nothing burns, so a
          -- parked copy of a real attestation's datum was clutter no sweep could ever reach.
          Cleanup -> case mdatum of
            Nothing -> True
            Just (Datum bd) -> case fromBuiltinData @AttestationsDatum bd of
              Nothing -> True
              Just (parkedDatum :: AttestationsDatum) ->
                traceIfFalse "A0" (Utils.isUnbackedDatum (attestationId (extra parkedDatum)) spendingTxOutRef txInfoInputs) -- Cannot cleanup backed state (A0)
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
                 in -- The attestation must not ALREADY be accepted. Its absence was the open half of
                    -- inherited fix #4: the off-chain path refuses a second accept
                    -- (AttestationAlreadyAccepted) but anyone building their own transaction bypasses
                    -- that, and a second accept rewrites an identical datum and passes — leaving a
                    -- permanent record whose acceptance is whatever the last accepter chose. Its own
                    -- trace code rather than folding into A1, because "already accepted" and "wrong
                    -- output" are different mistakes and an operator should be able to tell them apart.
                    --
                    -- One boolean read of a datum already parsed, so this is NOT the
                    -- non-exploitable-defence case the repo rejects: the off-chain guard is bypassable
                    -- and the consequence is permanent.
                    traceIfFalse "A3" (not (attestationIsAccepted attestation)) -- Already accepted (A3)
                      && traceIfFalse
                        "A1"
                        ( and
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
                        )
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
