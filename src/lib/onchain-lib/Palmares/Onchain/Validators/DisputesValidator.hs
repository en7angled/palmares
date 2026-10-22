{-# LANGUAGE MultiParamTypeClasses #-}
-- Required for `makeLift`:
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Use &&" #-}

-- | Disputes validator: a deposit goes in, the oracle admin writes a verdict, the deposit comes back.
--
-- __A dispute is a separate UTxO pointing at an attestation, never a field on one.__ That is what
-- keeps the attestation path's ExUnits exactly as they were — neither 'OnchainAttestation' nor the
-- Attestations Validator learns anything about disputes — and it is what lets a dispute exist without
-- the subject's or the issuer's cooperation. Spec §4.3: the dispute is shown beside the attestation
-- and __the attestation is never hidden or deleted__, which is a read-layer property and deliberately
-- not a validator one.
--
-- __What this validator does NOT enforce, said here so nothing downstream claims it does.__ "One open
-- dispute per attestation at a time" is not checked on chain: it would need an index UTxO that every
-- dispute had to contend for, which serialises dispute opening and buys a property the deposit
-- already provides. Each dispute is its own UTxO with its own deposit, so N disputes cost N deposits.
-- 'Palmares.Onchain.Protocol.Types.checkNoOpenDispute' is the off-chain courtesy that refuses the
-- duplicate a human would not have meant; it has no trace code here because there is no check.
--
-- __@D6@ is a different statement and must not be read as that one.__ It says one dispute may be
-- RESOLVED per transaction, which is a soundness requirement for @D4@ and not a limit on how many
-- disputes may exist. Opening is unbounded; resolving is serialised.
--
-- Unparameterised, like the Profiles and Attestations validators: its own address comes from the
-- input being spent, and the one external fact it needs — which reference input is the oracle — comes
-- from the token recorded in its own datum. A validator hash is never a parameter here.
module Palmares.Onchain.Validators.DisputesValidator
  ( -- * Disputes Redeemer
    DisputesRedeemer (..),

    -- * Disputes Validator
    disputesLambda,

    -- * Compilation
    disputesCompile,
  )
where

import GHC.Generics (Generic)
import Palmares.Onchain.CIP68
-- The barrel already re-exports Protocol.Lookup, so `readOracleParams` arrives with it; importing
-- that module by name as well is the redundant import CI flagged.
import Palmares.Onchain.Protocol
import Palmares.Onchain.Utils qualified as Utils
import PlutusLedgerApi.V1 qualified as V1
-- `geq` is not re-exported by PlutusLedgerApi.V1, so it is imported by name here the way
-- Palmares.Onchain.Utils does it.
import PlutusLedgerApi.V1.Value (geq)
import PlutusLedgerApi.V3
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.List qualified
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Disputes Redeemer

-------------------------------------------------------------------------------

-- Opening a dispute is the minting policy's business (@OpenDispute@, codes @Md1@-@Md8@), exactly as
-- issuing an attestation is. This validator owns only what happens to a dispute that already exists.
data DisputesRedeemer
  = -- | ResolveDispute verdict disputeOutputIdx
    ResolveDispute Verdict Integer
  | Cleanup
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''DisputesRedeemer [('ResolveDispute, 0), ('Cleanup, 1)]

type DisputesDatum = CIP68Datum OnchainDispute

-------------------------------------------------------------------------------

{-# INLINEABLE disputesLambda #-}
disputesLambda :: ScriptContext -> Bool
disputesLambda (ScriptContext TxInfo {..} (Redeemer bredeemer) scriptInfo) =
  let !redeemer = unsafeFromBuiltinData @DisputesRedeemer bredeemer
   in case scriptInfo of
        (SpendingScript spendingTxOutRef mdatum) -> case redeemer of
          -- Permissionless cleanup, the same shape the other two state validators use: a UTxO at this
          -- address is dust unless its own VALUE backs its datum's claim to be a dispute, and only a
          -- datum the dispute NFT backs is protocol state that nobody may sweep. \"Its datum parses\"
          -- was the old test and is not the same claim — see 'Utils.isUnbackedDatum'.
          --
          -- The NFT the datum names, 'disputeId', and never 'disputeTarget': the target is the
          -- ATTESTATION this dispute contests, which lives at another address entirely, so checking
          -- it would ask whether a dispute is backed by somebody else's token.
          Cleanup -> case mdatum of
            Nothing -> True
            Just (Datum bd) -> case fromBuiltinData @DisputesDatum bd of
              Nothing -> True
              Just (parkedDatum :: DisputesDatum) ->
                traceIfFalse "D0" (Utils.isUnbackedDatum (disputeId (extra parkedDatum)) spendingTxOutRef txInfoInputs) -- Cannot cleanup backed state (D0)
          ResolveDispute verdict outputIdx -> case mdatum of
            Nothing -> traceError "D0" -- No datum (D0)
            Just (Datum bdatum) -> case fromBuiltinData bdatum of
              Nothing -> traceError "D0" -- Invalid datum (D0)
              Just (disputeDatum :: DisputesDatum) ->
                let dispute = extra disputeDatum
                    ownInput = Utils.unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs
                    ownValue = txOutValue ownInput
                    ownAddress = txOutAddress ownInput
                    resolvedDatum = disputeDatum {extra = resolveDispute verdict dispute}
                    -- The deposit the dispute ACTUALLY paid, out of its own datum — never
                    -- `opDisputeDeposit` from the oracle. Reading the oracle here would let the admin
                    -- lower the price, resolve, and keep the difference; or raise it and make an open
                    -- dispute unresolvable. The oracle prices new disputes; an open one's price is
                    -- history.
                    depositValue = V1.lovelaceValue (V1.Lovelace (disputeDeposit dispute))
                    -- Read through the token recorded in the datum, so a forged "oracle" UTxO naming
                    -- the attacker as admin cannot be substituted. `readOracleParams` traces K1 when
                    -- no reference input carries that token.
                    oracle = readOracleParams (disputeOracleToken dispute) txInfoReferenceInputs
                    paysDeposit TxOut {txOutValue, txOutAddress} =
                      (txOutAddress == disputeDepositTo dispute) && (txOutValue `geq` depositValue)
                 in -- A PAUSE STOPS WRITES, NOT READS, and settling a dispute is a write. @opPaused@
                    -- used to be read by the minting policy alone (@M0@), so a paused protocol
                    -- refused new disputes while open ones could still be settled — the lever halted
                    -- the cheap, repeatable action and left the irreversible one running.
                    --
                    -- __This does not lock the admin out__, which is the objection to answer: the
                    -- oracle update path bypasses the pause on purpose, so the admin who paused can
                    -- unpause and then resolve. What it costs is the ability to settle disputes
                    -- DURING a pause, deliberately, because a pause that leaves verdicts being
                    -- written is not a stop.
                    --
                    -- __The off-chain builder is now the laxer of the two.__
                    -- 'Palmares.TxBuilding.Operations.resolveDisputeTX' reads the oracle directly
                    -- rather than through @getOracleRefInputSkeleton@, so while paused it still
                    -- BUILDS a resolution and this check is what refuses it — a script failure where
                    -- a @503 ProtocolPaused@ would read better. Adding that guard off chain is a
                    -- follow-up in that module; the chain is the authority either way.
                    --
                    -- Its own code and not folded into D1, for the reason D3 has its own: \"paused\"
                    -- and \"not the admin\" are different mistakes.
                    traceIfFalse "D7" (not (opPaused oracle)) -- Protocol is paused (D7)
                      -- A verdict is written ONCE. Without this, the admin could rewrite an upheld
                      -- dispute as rejected — or an attacker who later obtains the key could rewrite
                      -- history that was already settled. Its own code rather than folded into D2,
                      -- because "already resolved" and "wrong output" are different mistakes; the same
                      -- argument as the attestation path's A3.
                      && traceIfFalse "D3" (disputeVerdict dispute == Nothing) -- Already resolved (D3)
                      && traceIfFalse "D1" (PlutusTx.List.elem (opAdminPkh oracle) txInfoSignatories) -- Oracle admin must sign (D1)
                      && traceIfFalse
                        "D2" -- Dispute must return resolved, less the deposit (D2)
                        ( and
                            [ Utils.checkTxOutAtIndexWithDatumMinValueAndAddress
                                outputIdx
                                resolvedDatum
                                (ownValue - depositValue)
                                ownAddress
                                txInfoOutputs,
                              -- The spent UTxO must actually be this dispute, not something else
                              -- carrying a copy of its datum.
                              V1.assetClassValueOf ownValue (disputeId dispute) == 1
                            ]
                        )
                      -- THE DEPOSIT COMES BACK, ON EITHER VERDICT. There is no punitive outcome, which
                      -- is why `Verdict` has exactly two constructors: losing a dispute costs network
                      -- fees and nothing else, because a registry that charged for contesting a false
                      -- claim would be a registry that discourages contesting one. Paid to the address
                      -- the disputer named when opening, because a validator cannot resolve a
                      -- ProfileId into an address.
                      --
                      -- `any` IS A MULTIPLE-SATISFACTION HOLE WITHOUT D6 BELOW, and this is the site
                      -- that made the rule concrete: two disputes naming the same payout address are
                      -- the ordinary case — one person contesting two attestations — and resolving
                      -- both in one transaction let a single returned deposit discharge both checks,
                      -- with the second deposit landing in the change of whoever built the
                      -- transaction. D1 means that is the oracle admin. The `any` stays; D6 makes it
                      -- sound by ensuring there is only ever one obligation per transaction to
                      -- discharge.
                      && traceIfFalse "D4" (any paysDeposit txInfoOutputs) -- Deposit must return to the disputer (D4)
                      && traceIfFalse "D6" (Utils.spentExactlyOnceFromAddress ownAddress txInfoInputs) -- One dispute per transaction (D6)
        _ -> traceError "D5" -- Invalid script info (D5)

-------------------------------------------------------------------------------

-- * Compilation

-------------------------------------------------------------------------------

-- | Lose the types
{-# INLINEABLE disputesUntyped #-}
disputesUntyped :: BuiltinData -> BuiltinUnit
disputesUntyped = Utils.mkUntypedLambda disputesLambda

-- | Compile the untyped lambda to a UPLC script and splice back to Haskell.
disputesCompile :: CompiledCode (BuiltinData -> BuiltinUnit)
disputesCompile = $$(compile [||disputesUntyped||])
