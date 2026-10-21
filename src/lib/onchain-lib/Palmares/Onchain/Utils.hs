{-# LANGUAGE NoImplicitPrelude #-}

-- | On-chain utility functions shared across validators.
-- Provides helpers for untyped lambda conversion, datum/value lookups,
-- output validation, and oracle reading. Minimum lovelace for state outputs
-- comes from the oracle ('opMinUTxOValue'), not from this module.
module Palmares.Onchain.Utils
  ( -- * Helper Functions
    mkUntypedLambda,
    nameFromTxOutRef,

    -- * Datum Helper Functions
    checkTxOutAtIndexWithDatumValueAndAddress,
    isTxOutAtIndexWithDatumValueAndAddress,
    checkTxOutAtIndexWithDatumMinValueAndAddress,
    isTxOutAtIndexWithDatumMinValueAndAddress,
    isGivenInlineDatum,
    unsafeFindOwnInputByTxOutRef,

    -- * Validate and Get
    checkAndGetCurrentStateDatumAndValue,
    checkAndGetInlineDatum,

    -- * Asset Class Helpers
    hasCurrencySymbol,

    -- * Inputs Spend TxOutRef Helper Functions
    hasTxInAtAddressWithNFT,
    inputsSpendTxOutRef,

    -- * Credential Control
    checkCredentialControl,

    -- * Time
    checkDateInRange,
    maxDateWindow,
  )
where

import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Value
import PlutusLedgerApi.V3
import PlutusTx.Builtins
import PlutusTx.List qualified
import PlutusTx.Prelude

-------------------------------------------------------------------------------

-- * Helper Functions

-------------------------------------------------------------------------------

-- | Converts a typed validator lambda to the untyped form expected by Plutus.
{-# INLINEABLE mkUntypedLambda #-}
mkUntypedLambda ::
  (ScriptContext -> Bool) ->
  (BuiltinData -> BuiltinUnit)
mkUntypedLambda f c = check $ f (parseData c "U0") -- Invalid context (U0)
  where
    parseData mdata message = case fromBuiltinData mdata of
      Just d -> d
      _ -> traceError message

{-# INLINEABLE nameFromTxOutRef #-}
nameFromTxOutRef :: TxOutRef -> BuiltinByteString
nameFromTxOutRef (TxOutRef (TxId txIdbs) txIdx) = blake2b_224 (txIdbs `appendByteString` integerToByteString BigEndian 0 txIdx)

-------------------------------------------------------------------------------

-- * Datum Helper Functions

-------------------------------------------------------------------------------

-- | Check that the output at a specific index has the expected datum, value, and address.
-- This is more efficient than searching through all outputs with hasTxOutWithInlineDatumAndValue.
{-# INLINEABLE checkTxOutAtIndexWithDatumValueAndAddress #-}
checkTxOutAtIndexWithDatumValueAndAddress :: (ToData a) => Integer -> a -> Value -> Address -> [TxOut] -> Bool
checkTxOutAtIndexWithDatumValueAndAddress idx datum value address outputs =
  isTxOutAtIndexWithDatumValueAndAddress datum value address (outputs !! idx)

{-# INLINEABLE isTxOutAtIndexWithDatumValueAndAddress #-}
isTxOutAtIndexWithDatumValueAndAddress :: (ToData a) => a -> Value -> Address -> TxOut -> Bool
isTxOutAtIndexWithDatumValueAndAddress datum value address TxOut {txOutValue, txOutAddress, txOutDatum} =
  (value == txOutValue) && (address == txOutAddress) && isGivenInlineDatum datum txOutDatum

-- | Check that the output at a specific index has the expected datum and address, and that its value is >= minValue.
-- Use this in the minting policy where the exact output value depends on datum size (min-ADA); we only require value >= (minLv + NFT).
{-# INLINEABLE checkTxOutAtIndexWithDatumMinValueAndAddress #-}
checkTxOutAtIndexWithDatumMinValueAndAddress :: (ToData a) => Integer -> a -> Value -> Address -> [TxOut] -> Bool
checkTxOutAtIndexWithDatumMinValueAndAddress idx datum minValue address outputs =
  isTxOutAtIndexWithDatumMinValueAndAddress datum minValue address (outputs !! idx)

{-# INLINEABLE isTxOutAtIndexWithDatumMinValueAndAddress #-}
isTxOutAtIndexWithDatumMinValueAndAddress :: (ToData a) => a -> Value -> Address -> TxOut -> Bool
isTxOutAtIndexWithDatumMinValueAndAddress datum minValue address TxOut {txOutValue, txOutAddress, txOutDatum} =
  (txOutValue `geq` minValue) && (address == txOutAddress) && isGivenInlineDatum datum txOutDatum

{-# INLINEABLE hasTxInAtAddressWithNFT #-}
hasTxInAtAddressWithNFT :: AssetClass -> Address -> [TxInInfo] -> Bool
hasTxInAtAddressWithNFT ac address = any (\(TxInInfo _inOutRef (TxOut {txOutAddress, txOutValue})) -> (address == txOutAddress) && (V1.assetClassValueOf txOutValue ac == 1))

{-# INLINEABLE inputsSpendTxOutRef #-}
inputsSpendTxOutRef :: TxOutRef -> [TxInInfo] -> Bool
inputsSpendTxOutRef spendingTxOutRef = any ((== spendingTxOutRef) . txInInfoOutRef)

-------------------------------------------------------------------------------

-- * Time

-------------------------------------------------------------------------------

-- | Is this date inside the transaction's validity interval, with that interval actually bounded?
--
-- __Inherited fix #4.__ `onchain-lib/CLAUDE.md` requires that any date carried in a datum is
-- validated against the transaction's validity interval, and the inherited check was
-- @date \`before\` txInfoValidRange@. That blocks __future__-dating and leaves __back__-dating
-- completely unbounded: an attestation could claim 2015 and pass. The remedy is containment, not
-- precedence.
--
-- __Both bounds must be finite__, and that is the half the old check got wrong twice over.
-- @PlutusLedgerApi.V1.Interval.before@ is @False@ for a @NegInf@ lower bound, which happened to force
-- a lower bound for that one comparison — but containment alone would be satisfied by an interval with
-- no upper bound, and a transaction submitted with @always@ could then date a permanent record
-- anywhere. So the finiteness is required explicitly rather than inferred from whichever comparison
-- the caller happens to use.
--
-- __And the interval must be NARROW, which is the half fix #4 still got wrong.__ This function used
-- to be @isBounded range && member date range@, and its own Haddock gave the refutation away: it said
-- "the caller's window is what gives this meaning: off-chain builds a ~7h window from the chain tip".
-- The caller is whoever builds the transaction, and an attacker is a caller. Finiteness alone costs
-- them nothing: they submit @Interval (Finite 2015-01-01) (Finite now+2h)@, which is finite at both
-- ends, is accepted by the ledger because the current slot lies inside it, and contains any date they
-- like. So back-dating was still completely unbounded — exactly the hole fix #4 was written to close,
-- surviving the fix because containment was checked and WIDTH was not.
--
-- The remedy is to bound the width on chain, so "inside the interval" means "within hours of chain
-- time" because the validator says so, not because the honest builder happens to be polite.
--
-- __Why a constant and not an oracle parameter.__ Every other protocol constant here is oracle-tunable
-- precisely so a redeploy is not needed to change it, and this one deliberately is not: it is a
-- statement about what a date in this registry MEANS, not a price. An admin who could widen it could
-- retroactively make every back-dated record valid, which is the attack the bound exists to stop.
-- Promoting it later is a one-field change if the window is ever genuinely wrong.
--
-- The value is four times the off-chain builder's @safeEraTime@ (25920s, ~7h), so an honest
-- transaction built with that window has a wide margin, and a date more than about a day from chain
-- time is refused. A claim about an earlier event is self-reported and belongs in the claimed period
-- or in metadata, labelled as such — which is what those fields are for.
{-# INLINEABLE maxDateWindow #-}
maxDateWindow :: POSIXTime
maxDateWindow = POSIXTime 103680000 -- 4 * safeEraTime, in milliseconds

{-# INLINEABLE checkDateInRange #-}
checkDateInRange :: POSIXTime -> V1.POSIXTimeRange -> Bool
checkDateInRange date range = case range of
  V1.Interval (V1.LowerBound (V1.Finite lo) _) (V1.UpperBound (V1.Finite hi) _) ->
    hi - lo <= maxDateWindow && V1.member date range
  _ -> False

-------------------------------------------------------------------------------

-- * Credential Control

-------------------------------------------------------------------------------

-- | Does this transaction demonstrate control of the given credential?
--
-- __This is the identity claim's whole rule__, and the spec states it in one sentence: /prove you can
-- spend as that credential/. It applies identically to a DRep id, a constitutional-committee cold
-- credential and a stake credential, because all three are a 'Credential' — which is also what CIP-129
-- encodes, header byte included, so the key-or-script distinction is never thrown away.
--
--   * __A key credential__ is controlled by whoever can make the transaction carry its signature. One
--     list membership, and it is the @extra signatory@ the spec names.
--
--   * __A script credential__ is controlled by whoever can get the ledger to spend an input that
--     script governs — in the payment half of its address or in the staking half. We do not verify
--     the script's own condition and could not: if the ledger is spending that input, the condition
--     was /already/ satisfied, before this validator ran. A native timelock or multisig script has no
--     redeemer for us to inspect anyway, and committees and multisig organisations are the majority
--     case the spec calls out.
--
-- __The payment half ONLY, and the staking half is a security hole.__ This check used to read
-- @payment == credential || staking == Just (StakingHash credential)@, on the reasoning that a stake
-- credential which is a script appears in the staking half of an address, so checking only payment
-- would make "I cannot claim my own stake script" a support question. That reasoning is wrong, and
-- the mistake was treating an address as evidence.
--
-- Spending a UTxO proves control of its __payment__ credential and nothing else: that is the only
-- part the ledger's witness rule authenticates. The staking half is attacker-chosen data. A CIP-19
-- type-2 address — payment key hash plus stake SCRIPT hash — is perfectly ordinary and needs no
-- witness for the script, so anyone could send themselves 5 ADA to an address carrying their own key
-- in the payment half and a victim's script hash in the staking half, spend it with their own
-- signature, and the disjunct would accept it as proof of controlling the victim's credential. Every
-- script DRep id and every constitutional-committee cold script credential was claimable by anyone.
--
-- Nothing legitimate used it either: the off-chain prover
-- 'Palmares.TxBuilding.Operations.claimProofSkeleton' searches @utxosAtPaymentCredential@, so no
-- honest claim ever took that branch.
--
-- __What this costs, stated rather than hidden.__ A credential that is a stake script genuinely
-- cannot be claimed this way, because spending cannot witness it. The sound proof for one is a
-- withdrawal in @txInfoWdrl@, which the ledger DOES authenticate — not an address field. That is a
-- separate feature with its own ExUnits cost, and it is not needed for the credentials this registry
-- is about: a DRep id and a committee cold credential are the voter's own credential, not an
-- address's staking part.
--
-- __The documented limitation.__ A Plutus script that holds no UTxO at its own address — one that only
-- ever votes or withdraws — cannot claim in a single transaction. Its workaround is one transaction:
-- send yourself a UTxO at your own script address, then claim. We deliberately do __not__ inspect
-- @txInfoRedeemers@ to cover that case: it would cost ExUnits on every claim to serve a case whose
-- workaround is free, which is the trade this repository rejects by standing rule.
--
-- __What control is not.__ This proves control of a credential, not the identity of whoever holds it —
-- the only thing a chain can prove. Nothing downstream may phrase it as "is"; the wording is
-- "controls this credential".
--
-- Takes the two lists rather than a @TxInfo@ so that the rule is a pure function of its actual inputs:
-- it is cheaper to pass, and it is what makes the rule unit-testable without building a transaction.
{-# INLINEABLE checkCredentialControl #-}
checkCredentialControl :: Credential -> [PubKeyHash] -> [TxInInfo] -> Bool
checkCredentialControl credential signatories inputs = case credential of
  PubKeyCredential pkh -> PlutusTx.List.elem pkh signatories
  ScriptCredential _ -> any inputGovernedByCredential inputs
  where
    -- The PAYMENT half only. The staking half is not evidence; see the note above.
    inputGovernedByCredential (TxInInfo _ TxOut {txOutAddress = Address payment _}) =
      payment == credential

{-# INLINEABLE isGivenInlineDatum #-}
isGivenInlineDatum :: (ToData a) => a -> OutputDatum -> Bool
isGivenInlineDatum datum outdat = case outdat of
  OutputDatum da -> toBuiltinData datum == getDatum da
  _ -> False

{-# INLINEABLE unsafeFindOwnInputByTxOutRef #-}
unsafeFindOwnInputByTxOutRef :: TxOutRef -> [TxInInfo] -> TxOut
unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs =
  let i = PlutusTx.List.find (\TxInInfo {txInInfoOutRef} -> txInInfoOutRef == spendingTxOutRef) txInfoInputs
   in case i of
        Just (TxInInfo _inOutRef inOut) -> inOut
        Nothing -> traceError "U1" -- Cannot find own input by TxOutRef (U1)

-------------------------------------------------------------------------------

-- * Validate and Get - Datum and Value Helper Functions

-------------------------------------------------------------------------------

{-# INLINEABLE checkAndGetCurrentStateDatumAndValue #-}
checkAndGetCurrentStateDatumAndValue :: V1.AssetClass -> Address -> [TxInInfo] -> (Value, BuiltinData)
checkAndGetCurrentStateDatumAndValue stateToken addr outs =
  case filter (\(TxInInfo _inOutRef (TxOut {txOutValue, txOutAddress})) -> (txOutValue `geq` V1.assetClassValue stateToken 1) && (addr == txOutAddress)) outs of
    [TxInInfo _inOutRef out] -> (txOutValue out, checkAndGetInlineDatum out)
    _ -> traceError "U2" -- Cannot find state NFT at expected address (U2)

{-# INLINEABLE checkAndGetInlineDatum #-}
checkAndGetInlineDatum :: TxOut -> BuiltinData
checkAndGetInlineDatum out = case txOutDatum out of
  OutputDatum da -> getDatum da
  _ -> traceError "U3" -- Invalid output: expected inline datum (U3)

-------------------------------------------------------------------------------

-- * Asset Class Helpers

-------------------------------------------------------------------------------

-- | Check whether an 'AssetClass' belongs to the given 'CurrencySymbol'.
{-# INLINEABLE hasCurrencySymbol #-}
hasCurrencySymbol :: AssetClass -> CurrencySymbol -> Bool
hasCurrencySymbol (AssetClass (cs, _)) cs' = cs == cs'
