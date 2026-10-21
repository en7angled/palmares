{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Control of a Cardano credential — the rule the identity claim rests on.
--
-- __The rule, from the spec (§2, §4.3), is one sentence:__ prove you can spend as that credential.
--
--   * a __key__ credential is controlled by whoever can make the transaction carry its signature;
--   * a __script__ credential is controlled by whoever can get the ledger to spend an input that
--     script governs — because if the ledger is spending it, the script's own condition has already
--     been satisfied, before our validator ran. We do not re-check it and could not: a native
--     timelock or multisig script has no redeemer to inspect, and committees and multisig
--     organisations are the majority case the spec calls out.
--
-- __Why this is a unit test and not an emulator test.__ 'checkCredentialControl' is a pure function
-- of a signatory list and an input list, so the rule can be pinned without building a transaction.
-- The emulator cases that drive a real claim through @MintProfile@ are T-ATTEST-5's; these are the
-- reasoning, and they are what a reader should consult to learn what the claim does and does not
-- prove.
module UnitTests.Claim (tests) where

import Palmares.Onchain.Utils (checkCredentialControl)
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
import PlutusLedgerApi.V1.Value (AssetClass (..))
import PlutusLedgerApi.V1.Value qualified as V1
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "credential control"
    [ testCase "a key credential is controlled when its hash is a signatory" $
        checkCredentialControl (PubKeyCredential pkhA) [pkhA] [] @?= True,
      testCase "a key credential is not controlled by a different signatory" $
        checkCredentialControl (PubKeyCredential pkhA) [pkhB] [] @?= False,
      testCase "a key credential is controlled when its hash is one signatory among several" $
        checkCredentialControl (PubKeyCredential pkhA) [pkhB, pkhA, pkhB] [] @?= True,
      -- The script arm, both halves of an address.
      testCase "a script credential is controlled when an input's PAYMENT credential is that script" $
        checkCredentialControl (ScriptCredential shA) [] [inputPayingTo (ScriptCredential shA)] @?= True,
      -- Staking as well as payment, because a stake credential that is a script normally appears in
      -- THAT half of an address. One more field read per input, and it removes an entire class of
      -- "I cannot claim my own stake script".
      testCase "a script credential is controlled when an input's STAKING credential is that script" $
        checkCredentialControl (ScriptCredential shA) [] [inputStakedTo (ScriptCredential shA)] @?= True,
      testCase "a script credential is controlled when any ONE of several inputs matches" $
        checkCredentialControl
          (ScriptCredential shA)
          []
          [inputPayingTo (PubKeyCredential pkhB), inputPayingTo (ScriptCredential shA)]
          @?= True,
      testCase "a script credential is not controlled by an input at a DIFFERENT script" $
        checkCredentialControl (ScriptCredential shA) [] [inputPayingTo (ScriptCredential shB)] @?= False,
      -- The documented limitation, asserted rather than left implicit: a signature is not a
      -- substitute for the script running. A Plutus script holding no UTxO at its own address must
      -- first send itself one; that workaround is free, which is why no txInfoRedeemers check is
      -- added to cover it.
      testCase "a script credential is NOT controlled by a signature, however many" $
        checkCredentialControl (ScriptCredential shA) [pkhA, pkhB] [] @?= False,
      -- And the converse, which is the subtler of the two: the 28 bytes of a script hash and the 28
      -- bytes of a key hash are the same bytes. The header byte CIP-129 carries is what distinguishes
      -- them, and it must not be possible to satisfy one arm with the other's evidence.
      testCase "a key credential is NOT controlled by an input at a script of the same bytes" $
        checkCredentialControl (PubKeyCredential pkhFromShA) [] [inputPayingTo (ScriptCredential shA)]
          @?= False,
      testCase "a script credential is NOT controlled by a signature of the same bytes" $
        checkCredentialControl (ScriptCredential shFromPkhA) [pkhA] [] @?= False,
      testCase "nothing controls nothing" $
        ( checkCredentialControl (PubKeyCredential pkhA) [] [],
          checkCredentialControl (ScriptCredential shA) [] []
        )
          @?= (False, False),
      -- An input that carries a value is no more and no less controlling than an empty one: the rule
      -- is about who governs the input, never about what it holds.
      testCase "what the input holds does not matter, only whose credential governs it" $
        checkCredentialControl (ScriptCredential shA) [] [inputPayingToWithValue (ScriptCredential shA)]
          @?= True
    ]
  where
    pkhA = PubKeyHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1"
    pkhB = PubKeyHash "\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2"
    shA = ScriptHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"
    shB = ScriptHash "\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4\4"
    -- The same 28 bytes, read as the other kind of credential.
    pkhFromShA = let ScriptHash bs = shA in PubKeyHash bs
    shFromPkhA = let PubKeyHash bs = pkhA in ScriptHash bs

    inputPayingTo c = mkInput (Address c Nothing) mempty
    inputStakedTo c = mkInput (Address (PubKeyCredential pkhB) (Just (StakingHash c))) mempty
    inputPayingToWithValue c =
      mkInput (Address c Nothing) (V1.assetClassValue (AssetClass (V1.CurrencySymbol "ff", V1.TokenName "tok")) 1)

    mkInput addr val =
      TxInInfo
        (TxOutRef (TxId "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0") 0)
        TxOut
          { txOutAddress = addr,
            txOutValue = val,
            txOutDatum = NoOutputDatum,
            txOutReferenceScript = Nothing
          }
