{-# LANGUAGE OverloadedStrings #-}

-- | The guard against multiple satisfaction — the rule @D4@ needs to mean anything.
--
-- __The hole.__ A validator that discharges an obligation with @any@ over the transaction's outputs
-- is sound only while there is one instance of it per transaction. Spend two UTxOs at the same
-- script in one transaction and each instance runs its own check against the SAME output list, so
-- one output that satisfies both lets the second obligation be met for free.
--
-- The Disputes Validator's @D4@ was exactly this: the deposit had to come back with
-- @any paysDeposit txInfoOutputs@, and two disputes naming the same payout address — one person
-- contesting two attestations, which is the ordinary case — could be resolved together with ONE
-- deposit returned. The other deposit left the script into the transaction's change, and @D1@ means
-- the transaction was built by the oracle admin.
--
-- __Why this is a unit test.__ 'spentExactlyOnceFromAddress' is a pure function of an address and an
-- input list, so the rule is pinned here without building a transaction; @UnitTests.Dispute@ carries
-- the emulator case that drives two real disputes into one real transaction and asserts @D6@.
--
-- The first case is the one that fails on the old code, per @src/test/CLAUDE.md@.
module UnitTests.Satisfaction (tests) where

import Palmares.Onchain.Utils (spentExactlyOnceFromAddress)
import PlutusLedgerApi.V1.Value (AssetClass (..))
import PlutusLedgerApi.V1.Value qualified as V1
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (..),
    OutputDatum (NoOutputDatum),
    PubKeyHash (..),
    ScriptHash (..),
    StakingCredential (StakingHash),
    TxId (..),
    TxInInfo (..),
    TxOut (..),
    TxOutRef (..),
  )
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "multiple satisfaction"
    [ -- THE CASE THE OLD CODE HAD NO CHECK FOR AT ALL: two of this script's UTxOs in one
      -- transaction. Before D6 this shape validated, and one returned deposit discharged both
      -- disputes' D4.
      testCase "two inputs from the same script address is a refusal" $
        spentExactlyOnceFromAddress scriptAddr [inputAt scriptAddr, inputAt scriptAddr] @?= False,
      testCase "exactly one input from the address passes" $
        spentExactlyOnceFromAddress scriptAddr [inputAt scriptAddr] @?= True,
      -- Zero is a refusal rather than a vacuous pass. It cannot happen from the validator — the
      -- address is read off the input being spent, so there is always at least one — but a predicate
      -- that answered True for an empty list would be the wrong thing to reach for anywhere else.
      testCase "no input from the address is a refusal, not a vacuous pass" $
        spentExactlyOnceFromAddress scriptAddr [] @?= False,
      -- OTHER scripts and other people's inputs are none of its business: a dispute resolution may
      -- be paid for from an ordinary wallet, and the transaction may carry anything else.
      testCase "inputs at other addresses do not count, however many" $
        spentExactlyOnceFromAddress
          scriptAddr
          [inputAt walletAddr, inputAt scriptAddr, inputAt otherScriptAddr, inputAt walletAddr]
          @?= True,
      testCase "inputs at other addresses alone are still a refusal" $
        spentExactlyOnceFromAddress scriptAddr [inputAt walletAddr, inputAt otherScriptAddr] @?= False,
      -- The early exit must not change the answer when the second match is the LAST element, which
      -- is the case a short-circuiting counter gets wrong if it exits on the wrong side of the
      -- comparison.
      testCase "the second match at the end of a long list is still caught" $
        spentExactlyOnceFromAddress
          scriptAddr
          [inputAt scriptAddr, inputAt walletAddr, inputAt otherScriptAddr, inputAt scriptAddr]
          @?= False,
      testCase "three inputs from the address is a refusal" $
        spentExactlyOnceFromAddress scriptAddr (replicate 3 (inputAt scriptAddr)) @?= False,
      -- The address is compared WHOLE, staking half included, which is what makes this a statement
      -- about one script's UTxOs rather than about one payment credential's. Two UTxOs at the same
      -- script hash with different stake credentials are two different addresses and the ledger
      -- treats them as such, so the predicate must too — otherwise an attacker splits the batch
      -- across two staking variants of the same script and the count never reaches two.
      --
      -- The validator is safe either way because its own address comes from the input it is
      -- spending, so every instance compares against the address it was actually found at. This case
      -- records which of the two readings the function implements, because the other one is a
      -- plausible mistake to make while "fixing" it later.
      testCase "the staking half is part of the address being counted" $
        spentExactlyOnceFromAddress scriptAddr [inputAt scriptAddr, inputAt scriptAddrStaked] @?= True,
      -- And what the inputs HOLD is irrelevant: the count is about whose script governs them.
      testCase "what the inputs hold does not matter" $
        spentExactlyOnceFromAddress scriptAddr [inputAtWithValue scriptAddr, inputAt scriptAddr] @?= False
    ]
  where
    pkhA = PubKeyHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1"
    shA = ScriptHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"
    shB = ScriptHash "\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4"

    scriptAddr = Address (ScriptCredential shA) Nothing
    scriptAddrStaked = Address (ScriptCredential shA) (Just (StakingHash (PubKeyCredential pkhA)))
    otherScriptAddr = Address (ScriptCredential shB) Nothing
    walletAddr = Address (PubKeyCredential pkhA) Nothing

    inputAt addr = mkInput addr mempty
    inputAtWithValue addr =
      mkInput addr (V1.assetClassValue (AssetClass (V1.CurrencySymbol "ff", V1.TokenName "tok")) 1)

    mkInput addr val =
      TxInInfo
        (TxOutRef (TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0") 0)
        TxOut
          { txOutAddress = addr,
            txOutValue = val,
            txOutDatum = NoOutputDatum,
            txOutReferenceScript = Nothing
          }
