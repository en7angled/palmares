{-# LANGUAGE NoImplicitPrelude #-}

-- | The oracle read, and the fee it prices.
--
-- Three profile lookups used to live here — @unsafeGetProfile@, @unsafeGetProfileDatumAndValue@ and
-- @unsafeGetProtocolParamsFromProfileRefInput@ — and all three had zero callers. Every validator
-- reads a profile through @Utils.checkAndGetCurrentStateDatumAndValue@ directly, so these were a
-- second way to do it that nothing took. Deleting them also retires trace code @K3@, which existed
-- only inside the third one: it was never reachable, never pinned by a test and named in no
-- document, so the protocol's code alphabet loses a letter nothing could ever have read.
module Palmares.Onchain.Protocol.Lookup
  ( readOracleParams,
    feeFor,
    checkFee,
  )
where

import Palmares.Onchain.Protocol.Types
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Value
import PlutusLedgerApi.V3
import PlutusTx.List qualified
import PlutusTx.Prelude

-------------------------------------------------------------------------------

-- * Oracle Helpers

-------------------------------------------------------------------------------

-- | Read 'OracleParams' from the oracle UTxO identified by its NFT 'AssetClass'
-- in the transaction's reference inputs. Fails if the oracle UTxO is not found
-- or the datum cannot be decoded.
{-# INLINEABLE readOracleParams #-}
readOracleParams :: AssetClass -> [TxInInfo] -> OracleParams
readOracleParams oracleAC refInputs =
  case PlutusTx.List.find hasOracleNFT refInputs of
    Just (TxInInfo _ TxOut {txOutDatum}) -> case txOutDatum of
      OutputDatum (Datum bd) -> case fromBuiltinData @OracleParams bd of
        Just params -> params
        Nothing -> traceError "K1" -- Oracle read failed: cannot decode datum (K1)
      _ -> traceError "K1" -- Oracle read failed: must have inline datum (K1)
    Nothing -> traceError "K1" -- Oracle read failed: UTxO not found (K1)
  where
    hasOracleNFT (TxInInfo _ TxOut {txOutValue}) =
      V1.assetClassValueOf txOutValue oracleAC == 1

-- | The fee a 'MintAction' costs — __the only place a fee AMOUNT is selected__, which is the
-- claim that holds. This said "the only place in this codebase, on chain or off, where a
-- 'FeeConfig' field is named", and that is false: 'checkFee' below names @fcFeeAddress@,
-- @TxBuilding.Operations@ names it too, and @admin/Main.hs@ names all three to construct and
-- print a 'FeeConfig'. @scripts/check_vocabulary.sh@ states the real invariant — a 'FeeConfig'
-- field is named in exactly TWO places — and enforces that boundary, excluding the CLI and the
-- tests. The reason the rule exists is unchanged: inherited fix #1 was a selector shape that
-- let one call site name the wrong field, and one SELECTION site is what prevents it.
--
-- That is the whole of inherited fix #1. The inherited 'checkFee' took a @(FeeConfig -> Integer)@
-- selector, so every call site named a field, and one of them named the wrong one: the Belt System's
-- interval fee charged the membership-history field for years. An action cannot be mistyped into a
-- different field, and this function is exhaustive, so a new minting redeemer that forgets its fee is
-- a compile error.
-- __Opening a dispute carries no protocol fee__, and that is a product decision rather than an
-- omission: the deposit already bounds dispute spam and it comes BACK on either verdict, so the only
-- unrecoverable cost of contesting a false claim is network fees. A protocol fee on top would make
-- contesting cost money you never get back, which is a tax on exactly the behaviour this registry
-- wants. If one is ever wanted it is a @fcDisputeFee@ field and one arm here.
{-# INLINEABLE feeFor #-}
feeFor :: MintAction -> FeeConfig -> Integer
feeFor MintActionProfile = fcProfileCreationFee
feeFor MintActionAttestation = fcAttestationFee
feeFor MintActionDispute = const 0

-- | Check that a fee payment is included in the transaction outputs.
-- If 'opFeeConfig' is 'Nothing', no fee is required and the check passes.
-- If 'opFeeConfig' is 'Just', validates that at least one output pays
-- >= the fee 'feeFor' gives for this action to 'fcFeeAddress'.
--
-- Takes the __action__, never a selector. See 'feeFor'.
{-# INLINEABLE checkFee #-}
checkFee :: OracleParams -> MintAction -> [TxOut] -> Bool
checkFee oracle action outputs = case opFeeConfig oracle of
  Nothing -> True
  Just feeConfig
    -- A zero fee is NO fee. Without this the check would demand an output to the fee address
    -- carrying at least zero lovelace, which no honest transaction has a reason to build — so
    -- `OracleSetFees (Just cfg)` with any zero field would have bricked that action until the admin
    -- noticed. MintActionDispute is free by design and would have hit it immediately; the two
    -- existing actions could have hit it the first time anyone priced one at nothing.
    | feeFor action feeConfig <= 0 -> True
  Just feeConfig ->
    let requiredFee = feeFor action feeConfig
        feeAddr = fcFeeAddress feeConfig
        feeValue = V1.lovelaceValue (V1.Lovelace requiredFee)
     in traceIfFalse "K2" -- Must pay required fee (K2)
          $ any
            ( \TxOut {txOutValue = v, txOutAddress = a} ->
                a == feeAddr && v `geq` feeValue
            )
            outputs