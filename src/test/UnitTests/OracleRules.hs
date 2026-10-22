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
import Palmares.Onchain.Utils (checkDateInRange, maxDateWindow)
import Palmares.TxBuilding.Skeletons (safeEraTime)
import PlutusLedgerApi.V1.Interval (Interval (..), from, interval, lowerBound, strictLowerBound, strictUpperBound, to)
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
        checkDateInRange (t 100) always @?= False,
      -- ---------------------------------------------------------------------------------------
      -- FIX #4 WAS STILL OPEN, and an adversarial audit found it. Everything above tests
      -- containment and finiteness, and the attacker pays nothing for either: they submit an
      -- interval that is finite at BOTH ends and simply very wide. The ledger accepts it, because
      -- the current slot lies inside it, and any date they like lies inside it too.
      --
      -- The function's own Haddock gave it away — it said "the caller's window is what gives this
      -- meaning: off-chain builds a ~7h window". The caller is whoever builds the transaction, and
      -- an attacker is a caller. So the width is now checked on chain, and these are the cases that
      -- fail on the old code.
      testCase "a WIDE but finite interval is rejected, which is how back-dating survived fix #4" $
        checkDateInRange (t 0) (interval (t 0) (maxDateWindow + 1)) @?= False,
      testCase "a far back-dated record inside a wide finite interval is rejected" $
        checkDateInRange (t 1) (interval (t 1) (maxDateWindow + 1000)) @?= False,
      -- The boundary, both sides, so the bound is a decision and not an accident.
      testCase "an interval exactly maxDateWindow wide is still accepted" $
        checkDateInRange (t 1) (interval (t 1) (1 + maxDateWindow)) @?= True,
      -- And the honest builder keeps working. The width comes from the off-chain constant rather
      -- than a copy of its value, which makes this a CROSS-LAYER invariant: if anyone changes
      -- `safeEraTime`, this goes red and the on-chain bound becomes a decision again instead of a
      -- coincidence. `txIsValidForSafeEra` builds exactly `[tip, tip + safeEraTime]`, so the honest
      -- width is a deterministic 1x and never varies.
      testCase "an interval of exactly the off-chain builder's width is accepted" $
        checkDateInRange (t 1000) (interval (t 1000) (t 1000 + honestWidth)) @?= True,
      -- The ratio itself, because it is the whole argument for the bound's value. 2x and not 4x
      -- (the surplus was purely the attacker's back-dating reach, 28.8h of it), and not 1x, where
      -- the honest width would equal the bound and pass only by the `<=`.
      testCase "the bound is exactly twice the width the off-chain builder produces" $
        maxDateWindow @?= 2 * honestWidth,
      -- ---------------------------------------------------------------------------------------
      -- THE PRODUCTION SHAPE, which nothing above tests. `cardano-ledger-alonzo`'s
      -- `transValidityInterval` translates a two-sided validity interval as
      -- @Interval (lowerBound t1) (strictUpperBound t2)@ — closed below, OPEN above — so every real
      -- transaction reaches a validator with an EXCLUSIVE upper bound, while every case above uses
      -- `interval`, which is closed at both ends. Read out of
      -- cardano-ledger-alonzo-1.13.0.0's own source, not recalled.
      --
      -- These three pass on the current code, and that is the point: they pin the semantics BEFORE
      -- anyone rewrites `checkDateInRange` to avoid the `Interval` library for script bytes. The
      -- obvious rewrite, @lo <= date && date <= hi@, accepts a date exactly equal to `hi` that
      -- `member` rejects — a one-millisecond shift on the only path that dates a permanent record,
      -- and the whole suite would have stayed green through it.
      --
      -- The WIDTH check deliberately ignores the closures and compares the raw @hi - lo@. That
      -- over-counts an open-bounded interval's real width by at most 1 ms, which is the safe
      -- direction: it can only refuse, never admit.
      testCase "an exclusive upper bound excludes its own instant, as Interval does" $
        checkDateInRange (t 110) (Interval (lowerBound (t 90)) (strictUpperBound (t 110))) @?= False,
      testCase "one millisecond inside an exclusive upper bound is accepted" $
        checkDateInRange (t 109) (Interval (lowerBound (t 90)) (strictUpperBound (t 110))) @?= True,
      testCase "an exclusive lower bound excludes its own instant" $
        checkDateInRange (t 90) (Interval (strictLowerBound (t 90)) (strictUpperBound (t 110))) @?= False,
      -- And the raw-width claim above, which was prose with no test behind it until an independent
      -- reader pointed that out — the exact shape this file keeps finding elsewhere. The closure
      -- moves the MEMBERSHIP boundary and leaves the WIDTH boundary alone, so an interval that is
      -- exclusive at the top and exactly `maxDateWindow` wide still passes: `hi - lo` satisfies the
      -- `<=` on the raw bounds, and `member` holds because the inclusive upper bound is the instant
      -- below `hi`.
      testCase "an exclusive-ended interval exactly maxDateWindow wide still passes the width check" $
        checkDateInRange (t 1) (Interval (lowerBound (t 1)) (strictUpperBound (1 + maxDateWindow))) @?= True
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

    -- The validity-interval width `Palmares.TxBuilding.Skeletons.txIsValidForSafeEra` produces, in
    -- milliseconds. `safeEraTime` is in SLOTS, and a slot is one second on preprod and mainnet.
    honestWidth :: POSIXTime
    honestWidth = POSIXTime (safeEraTime * 1000)

    -- Read the constructor index straight out of the encoding, which is what a deployed validator
    -- sees — rather than trusting the makeIsDataSchemaIndexed call to say what it means.
    constructorIndexOf x = case builtinDataToData (toBuiltinData x) of
      Constr i _ -> i
      _ -> -1
