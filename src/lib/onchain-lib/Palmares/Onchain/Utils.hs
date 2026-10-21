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
-- __Why the staking half as well as the payment half.__ A stake credential that is a script normally
-- appears in the staking half of an address, not the payment half, so checking only payment would make
-- "I cannot claim my own stake script" a permanent support question. It costs one more field read per
-- input, and it is `onchain-lib/CLAUDE.md`'s security rule 13 — reason about full addresses — applied
-- in the useful direction.
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
    inputGovernedByCredential (TxInInfo _ TxOut {txOutAddress = Address payment staking}) =
      payment == credential || staking == Just (StakingHash credential)

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
