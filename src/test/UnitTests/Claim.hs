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
      -- THE CASE THIS TEST USED TO ASSERT THE OTHER WAY, and the audit's one critical finding.
      --
      -- It read `@?= True`, on the reasoning that a stake credential which is a script appears in
      -- the staking half of an address. The reasoning mistook an address for evidence. Spending a
      -- UTxO authenticates its PAYMENT credential and nothing else; the staking half is data the
      -- address's creator chose freely. A CIP-19 type-2 address — payment key hash plus stake script
      -- hash — needs no witness for the script, so anyone could send themselves min-ADA to an
      -- address holding their own key in the payment half and a victim's script hash in the staking
      -- half, spend it with their own signature, and claim the victim's credential. Every script
      -- DRep id and every committee cold script credential was claimable by anyone, permanently,
      -- because `profileCredential` has no update redeemer and nothing burns a profile.
      --
      -- So this is now the assertion that fails on the old code, which is what `src/test/CLAUDE.md`
      -- asks of every fix.
      testCase "a script credential is NOT controlled by an input that merely STAKES to it" $
        checkCredentialControl (ScriptCredential shA) [] [inputStakedTo (ScriptCredential shA)] @?= False,
      -- And the payment half still works when a staking part is present, so the fix removed the hole
      -- and not the feature: a script UTxO that happens to carry a stake credential is still proof.
      testCase "a script credential IS controlled when it is the payment half of a staked address" $
        checkCredentialControl
          (ScriptCredential shA)
          []
          [inputPayingToStaked (ScriptCredential shA) (PubKeyCredential pkhB)]
          @?= True,
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
    -- The attacker's address: THEIR key in the payment half, the victim's credential in the staking
    -- half. Needs no witness for the staking credential, which is the whole point.
    inputStakedTo c = mkInput (Address (PubKeyCredential pkhB) (Just (StakingHash c))) mempty
    -- A legitimate script UTxO that also carries a stake credential.
    inputPayingToStaked c stake = mkInput (Address c (Just (StakingHash stake))) mempty
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
