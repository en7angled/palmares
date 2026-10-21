{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The dispute protocol's pure rules.
--
-- Everything here is a function of the on-chain types, so it can be pinned without the emulator; the
-- cases that drive a real deposit through a real transaction are T-ATTEST-5's.
--
-- Two of these tests are about things the chain deliberately does NOT enforce, and they are here so
-- that the boundary is written down rather than assumed:
--
--   * 'checkNoOpenDispute' is an off-chain courtesy. There is no trace code for it, because there is
--     no on-chain check: "one open dispute at a time" would need an index UTxO every dispute had to
--     contend for. What bounds spam is the deposit — N disputes cost N deposits.
--   * the deposit comes back on BOTH verdicts, so losing a dispute costs only network fees. There is
--     no punitive verdict, and that is why 'Verdict' has exactly two constructors.
module UnitTests.Dispute (tests) where

import Palmares.Onchain.Protocol.Lookup (checkFee, feeFor)
import Palmares.Onchain.Protocol.Types
  ( FeeConfig (..),
    MintAction (..),
    OnchainDispute (..),
    OracleParams (..),
    Verdict (..),
    checkNoOpenDispute,
    resolveDispute,
  )
import Palmares.Onchain.Utils (nameFromTxOutRef)
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusLedgerApi.V3
  ( Address (..),
    Credential (PubKeyCredential),
    POSIXTime (..),
    PubKeyHash (..),
    TxId (..),
    TxOutRef (..),
  )
import PlutusTx (Data (..), builtinDataToData, toBuiltinData)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "disputes"
    [ -- A dispute's token name comes from the seed TxOutRef it spends, which is what makes two
      -- disputes against the same attestation distinct UTxOs rather than a collision. Same primitive
      -- the minting policy uses, so this is the real derivation and not a restatement of it.
      testCase "a dispute's name is derived from its seed, so two disputes never collide" $
        (nameFromTxOutRef seedA /= nameFromTxOutRef seedB) @?= True,
      testCase "the same seed always derives the same name" $
        nameFromTxOutRef seedA @?= nameFromTxOutRef seedA,
      testCase "an unresolved dispute carries no verdict" $
        disputeVerdict (freshDispute targetA openerA) @?= Nothing,
      -- Whole-record equality, not a field read: the validator computes the expected output datum
      -- with this function and compares the WHOLE datum, so anything resolveDispute preserves is a
      -- field the resolution provably cannot touch. A field read would pass even if resolving also
      -- quietly rewrote the target.
      testCase "resolving writes the verdict and changes nothing else" $
        resolveDispute VerdictUpheld (freshDispute targetA openerA)
          @?= (freshDispute targetA openerA) {disputeVerdict = Just VerdictUpheld},
      testCase "Verdict is two constructors at indices 0 and 1" $
        map constructorIndexOf [VerdictUpheld, VerdictRejected] @?= [0, 1],
      -- THE DEPOSIT COMES BACK EITHER WAY. The pure half of it: resolution cannot change the amount
      -- recorded at open time or the address it returns to, under either verdict. The validator's D4
      -- then pays exactly that recorded amount to exactly that address, which is why losing a
      -- dispute costs only network fees — and why there is no third, punitive verdict.
      testCase "neither verdict can change the recorded deposit or its destination" $
        map
          (\v -> let d = resolveDispute v (freshDispute targetA openerA) in (disputeDeposit d, disputeDepositTo d))
          [VerdictUpheld, VerdictRejected]
          @?= replicate 2 (disputeDeposit (freshDispute targetA openerA), depositAddr),
      -- ---- checkNoOpenDispute: off-chain courtesy, not a protocol rule ------------------------
      testCase "a second dispute against the same attestation is refused while one is open" $
        checkNoOpenDispute targetA [freshDispute targetA openerB] @?= False,
      testCase "a second dispute is allowed once the first is resolved" $
        checkNoOpenDispute targetA [resolveDispute VerdictRejected (freshDispute targetA openerB)] @?= True,
      -- Target-scoped, which is the half that would be silently wrong if the predicate ignored the
      -- target: every attestation would look contested as soon as any dispute was open anywhere.
      testCase "an open dispute against a DIFFERENT attestation does not block this one" $
        checkNoOpenDispute targetA [freshDispute targetB openerB] @?= True,
      testCase "no disputes at all is not an open dispute" $
        checkNoOpenDispute targetA [] @?= True,
      -- ---- fees -------------------------------------------------------------------------------
      testCase "MintActionDispute is at constructor index 2" $
        constructorIndexOf MintActionDispute @?= 2,
      -- Opening a dispute carries no protocol fee, whatever the oracle has priced the others at.
      -- Contesting a false claim must not cost money that never comes back.
      testCase "a dispute carries no protocol fee, for any fee configuration" $
        feeFor MintActionDispute feeCfg @?= 0,
      -- The reason `checkFee` needed a zero-fee short circuit. Without it the check demands an
      -- output to the fee address carrying at least ZERO lovelace, which no honest transaction
      -- builds — so a dispute would have been unmintable the moment fees were configured at all,
      -- and `OracleSetFees` with any zero field would have bricked that action. This is the case
      -- that fails on the old code.
      testCase "a zero fee requires no fee output at all" $
        checkFee oracleWithFees MintActionDispute [] @?= True,
      testCase "a priced action still requires its fee output" $
        checkFee oracleWithFees MintActionAttestation [] @?= False,
      testCase "no fee configuration means no fee for any action" $
        map (\a -> checkFee oracleNoFees a []) [MintActionProfile, MintActionAttestation, MintActionDispute]
          @?= [True, True, True]
    ]
  where
    cs = CurrencySymbol "\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10"
    acOf name = AssetClass (cs, TokenName name)

    targetA = acOf "\0\6C\176target-a"
    targetB = acOf "\0\6C\176target-b"
    openerA = acOf "\0\6C\176opener-a"
    openerB = acOf "\0\6C\176opener-b"

    pkh = PubKeyHash "\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3\3"
    depositAddr = Address (PubKeyCredential pkh) Nothing

    seedA = TxOutRef (TxId "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1") 0
    seedB = TxOutRef (TxId "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1") 1

    freshDispute target opener =
      OnchainDispute
        { disputeId = acOf "\0\6C\176dispute",
          disputeTarget = target,
          disputeOpenedBy = opener,
          disputeOpenedAt = POSIXTime 1_700_000_000_000,
          disputeDeposit = 5_000_000,
          disputeDepositTo = depositAddr,
          disputeOracleToken = acOf "oracle",
          disputeVerdict = Nothing
        }

    feeCfg =
      FeeConfig
        { fcFeeAddress = depositAddr,
          fcProfileCreationFee = 2_000_000,
          fcAttestationFee = 1_000_000
        }

    oracleWithFees = baseOracle {opFeeConfig = Just feeCfg}
    oracleNoFees = baseOracle

    baseOracle =
      OracleParams
        { opAdminPkh = pkh,
          opPaused = False,
          opFeeConfig = Nothing,
          opMinUTxOValue = 2_000_000,
          opDisputeDeposit = 5_000_000
        }

    -- Read the constructor index straight out of the encoding, which is what a deployed validator
    -- sees — rather than trusting the makeIsDataSchemaIndexed call to say what it means.
    constructorIndexOf x = case builtinDataToData (toBuiltinData x) of
      Constr i _ -> i
      _ -> -1
