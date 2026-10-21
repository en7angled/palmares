{-# LANGUAGE OverloadedStrings #-}

-- | The oracle's admin rules and the datum date bound — inherited fixes #2 and #4.
--
-- Both are tested here because both are pure functions of the on-chain types, so the rules can be
-- pinned without the emulator; the emulator cases that drive a real rotation and a real back-dated
-- mint through a transaction are T-ATTEST-5's.
--
-- Each group's first negative case is deliberately the OLD behaviour, per @src/test/CLAUDE.md@'s rule
-- that every inherited fix gets a test that fails on it.
module UnitTests.OracleRules (tests) where

import Palmares.Onchain.Protocol.Types
  ( OracleAdminAction (..),
    OracleParams (..),
    applyOracleAdminAction,
  )
import Palmares.Onchain.Utils (checkDateInRange)
import PlutusLedgerApi.V1.Interval (from, interval, to)
import PlutusLedgerApi.V3 (POSIXTime (..), PubKeyHash (..), always)
import PlutusTx (Data (..), builtinDataToData, toBuiltinData)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "oracle rules"
    [ -- ---------------------------------------------------------------------------------------
      -- Inherited fix #2. Rotation was not merely unimplemented: the validator FORBADE it, because
      -- O2 requires the output datum to equal applyOracleAdminAction of the current one and that
      -- function preserved opAdminPkh by construction. So the validator needs no change — the fix is
      -- to make this function able to express the change, which is the cheapest possible fix and is
      -- cheap because the validator was written correctly.
      testCase "applyOracleAdminAction rotates the admin, which it could not before (fix #2)" $
        opAdminPkh (applyOracleAdminAction (OracleSetAdmin pkhB) (paramsAdmin pkhA)) @?= pkhB,
      testCase "rotation changes nothing else in OracleParams" $
        applyOracleAdminAction (OracleSetAdmin pkhB) (paramsAdmin pkhA) @?= paramsAdmin pkhB,
      -- The other four actions must still leave the admin alone, or a repricing would hand the
      -- protocol to whoever built the transaction.
      testCase "no other admin action touches the admin key" $
        map (opAdminPkh . (`applyOracleAdminAction` paramsAdmin pkhA)) otherActions
          @?= replicate (length otherActions) pkhA,
      -- APPENDED at index 4, never inserted: the four existing indices are a deployed-data contract
      -- from the first deployment, and T-ATTEST-10 is where that binds.
      testCase "OracleSetAdmin is at constructor index 4" $
        constructorIndexOf (OracleSetAdmin pkhA) @?= 4,
      testCase "the four inherited actions keep indices 0 to 3" $
        map constructorIndexOf inheritedActions @?= [0, 1, 2, 3],
      -- Appended at 5 for the dispute deposit, same discipline.
      testCase "OracleSetDisputeDeposit is at constructor index 5" $
        constructorIndexOf (OracleSetDisputeDeposit 5_000_000) @?= 5,
      testCase "repricing the dispute deposit changes nothing else" $
        applyOracleAdminAction (OracleSetDisputeDeposit 7_000_000) (paramsAdmin pkhA)
          @?= (paramsAdmin pkhA) {opDisputeDeposit = 7_000_000},
      -- ---------------------------------------------------------------------------------------
      -- Inherited fix #4. The old check was `date `before` txInfoValidRange`, which blocks
      -- future-dating but leaves BACK-dating unbounded — an attestation could claim 2015. The rule
      -- from onchain-lib/CLAUDE.md is that a date in a datum is validated against the validity
      -- interval, and "against" means inside it.
      testCase "a back-dated value is rejected — the old check accepted any past date (fix #4)" $
        checkDateInRange (t 10) (interval (t 90) (t 110)) @?= False,
      testCase "a date inside the validity interval is accepted" $
        checkDateInRange (t 100) (interval (t 90) (t 110)) @?= True,
      testCase "a future-dated value is rejected" $
        checkDateInRange (t 200) (interval (t 90) (t 110)) @?= False,
      testCase "both interval bounds are inclusive, so a tx at the boundary is not a coin flip" $
        ( checkDateInRange (t 90) (interval (t 90) (t 110)),
          checkDateInRange (t 110) (interval (t 90) (t 110))
        )
          @?= (True, True),
      -- An unbounded lower bound is the shape `before` was happy with, and it is what made
      -- back-dating free. It must not be enough.
      testCase "an interval with no lower bound is rejected, so NegInf cannot mean 'any past'" $
        checkDateInRange (t 100) (to (t 110)) @?= False,
      testCase "an interval with no upper bound is rejected too" $
        checkDateInRange (t 100) (from (t 90)) @?= False,
      testCase "the always interval is rejected, so an unbounded tx cannot date a record freely" $
        checkDateInRange (t 100) always @?= False
    ]
  where
    pkhA = PubKeyHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1"
    pkhB = PubKeyHash "\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2\2"

    -- The four that existed before the rotation fix. Kept as its own list because the index
    -- assertion below is about THEM — folding the newer actions in would turn "0 to 3" into a list
    -- of whatever happens to be appended, which is the opposite of what that test is for.
    inheritedActions = [OraclePause, OracleUnpause, OracleSetFees Nothing, OracleSetMinUTxOValue 1_000_000]

    otherActions = inheritedActions <> [OracleSetDisputeDeposit 3_000_000]

    paramsAdmin pkh =
      OracleParams
        { opAdminPkh = pkh,
          opPaused = False,
          opFeeConfig = Nothing,
          opMinUTxOValue = 2_000_000,
          opDisputeDeposit = 5_000_000
        }

    t = POSIXTime

    -- Read the constructor index straight out of the encoding, which is what a deployed validator
    -- sees — rather than trusting the makeIsDataSchemaIndexed call to say what it means.
    constructorIndexOf x = case builtinDataToData (toBuiltinData x) of
      Constr i _ -> i
      _ -> -1
