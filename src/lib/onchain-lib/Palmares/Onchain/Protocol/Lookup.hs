{-# LANGUAGE NoImplicitPrelude #-}

-- | Typed datum lookup helpers for extracting protocol data from transaction inputs.
-- Each function locates the UTxO carrying a specific state NFT and deserializes
-- the inline datum into the expected on-chain type.
module Palmares.Onchain.Protocol.Lookup
  ( unsafeGetProfile,
    unsafeGetProfileDatumAndValue,
    unsafeGetProtocolParamsFromProfileRefInput,
    readOracleParams,
    feeFor,
    checkFee,
  )
where

import Palmares.Onchain.CIP68 (CIP68Datum (..), extra)
import Palmares.Onchain.Protocol.Types
import Palmares.Onchain.Utils (checkAndGetCurrentStateDatumAndValue)
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Value
import PlutusLedgerApi.V3
import PlutusTx.List qualified
import PlutusTx.Prelude

-- | Look up a profile datum (unwrapped from CIP68) from transaction inputs. Fails if not found.
{-# INLINEABLE unsafeGetProfile #-}
unsafeGetProfile :: ProfileId -> Address -> [TxInInfo] -> OnchainProfile
unsafeGetProfile ac addr txins =
  let (_, b) = checkAndGetCurrentStateDatumAndValue ac addr txins
   in extra (unsafeFromBuiltinData b :: CIP68Datum OnchainProfile)

-- | Look up a CIP68 profile datum and its UTxO value from transaction inputs. Fails if not found.
{-# INLINEABLE unsafeGetProfileDatumAndValue #-}
unsafeGetProfileDatumAndValue :: ProfileId -> Address -> [TxInInfo] -> (Value, CIP68Datum OnchainProfile)
unsafeGetProfileDatumAndValue ac addr txins =
  let (v, b) = checkAndGetCurrentStateDatumAndValue ac addr txins
   in (v, unsafeFromBuiltinData b :: CIP68Datum OnchainProfile)

-- | Get 'ProtocolParams' from the profile UTxO in reference inputs.
-- Finds the ref input whose value contains the given profile Ref 'AssetClass' (ProfileId)
-- with quantity 1, parses its inline datum as 'CIP68Datum OnchainProfile', returns 'protocolParams'.
-- The pattern a minting path uses to read protocol params without spending the profile UTxO.
{-# INLINEABLE unsafeGetProtocolParamsFromProfileRefInput #-}
unsafeGetProtocolParamsFromProfileRefInput :: ProfileId -> [TxInInfo] -> ProtocolParams
unsafeGetProtocolParamsFromProfileRefInput profileRefAC refInputs =
  case PlutusTx.List.find hasProfileRef refInputs of
    Just (TxInInfo _ TxOut {txOutDatum}) -> case txOutDatum of
      OutputDatum (Datum bd) ->
        let profile = extra (unsafeFromBuiltinData bd :: CIP68Datum OnchainProfile)
         in protocolParams profile
      _ -> traceError "K3" -- Profile ref input must have inline datum (K3)
    Nothing -> traceError "K3" -- Profile ref input not found (K3)
  where
    hasProfileRef (TxInInfo _ TxOut {txOutValue}) =
      V1.assetClassValueOf txOutValue profileRefAC == 1

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