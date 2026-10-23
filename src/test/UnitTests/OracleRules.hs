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
    oracleParamsAreWellFormed,
  )
import Palmares.Onchain.Utils (checkDateInRange, maxDateWindow)
import Palmares.TxBuilding.Skeletons (safeEraTime)
import PlutusLedgerApi.V1.Interval (Interval (..), from, interval, lowerBound, strictLowerBound, strictUpperBound, to)
import Data.ByteString qualified as BS
import PlutusLedgerApi.V3 (Credential (PubKeyCredential, ScriptCredential), POSIXTime (..), PubKeyHash (..), ScriptHash (..), always)
import PlutusTx.Builtins (toBuiltin)
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
      -- function preserved the admin field by construction. So the validator needs no change — the
      -- fix is to make this function able to express the change, which is the cheapest possible fix
      -- and is cheap because the validator was written correctly.
      testCase "applyOracleAdminAction rotates the admin, which it could not before (fix #2)" $
        opAdmin (applyOracleAdminAction (OracleSetAdmin (PubKeyCredential pkhB)) (paramsAdmin pkhA))
          @?= PubKeyCredential pkhB,
      -- ADR 0005: the target may be a script, which is the whole reason the field is a `Credential`.
      -- A `PubKeyHash` could not name a native multisig, so "start on one key and move to a multisig
      -- later" would have needed a new datum format — i.e. a new registry.
      testCase "the admin may be rotated to a SCRIPT credential (ADR 0005)" $
        opAdmin (applyOracleAdminAction (OracleSetAdmin scriptCred) (paramsAdmin pkhA)) @?= scriptCred,
      testCase "rotating the admin leaves the arbiter alone" $
        opArbiter (applyOracleAdminAction (OracleSetAdmin scriptCred) (paramsAdmin pkhA))
          @?= PubKeyCredential pkhA,
      -- The split is only real if it can be made. An arbiter that could not be rotated would be
      -- OC-01 reintroduced over other people's deposits.
      testCase "OracleSetArbiter moves the arbiter and nothing else (ADR 0005)" $
        applyOracleAdminAction (OracleSetArbiter scriptCred) (paramsAdmin pkhA)
          @?= (paramsAdmin pkhA) {opArbiter = scriptCred},
      testCase "rotation changes nothing else in OracleParams" $
        applyOracleAdminAction (OracleSetAdmin (PubKeyCredential pkhB)) (paramsAdmin pkhA)
          @?= (paramsAdmin pkhA) {opAdmin = PubKeyCredential pkhB},
      -- The other actions must still leave the admin alone, or a repricing would hand the
      -- protocol to whoever built the transaction.
      testCase "no other admin action touches the admin credential" $
        map (opAdmin . (`applyOracleAdminAction` paramsAdmin pkhA)) otherActions
          @?= replicate (length otherActions) (PubKeyCredential pkhA),
      -- And the same for the arbiter, including the admin rotation itself, which is the pair that
      -- would make the split a lie if either leaked into the other.
      testCase "no other admin action touches the arbiter credential" $
        map (opArbiter . (`applyOracleAdminAction` paramsAdmin pkhA)) otherActions
          @?= replicate (length otherActions) (PubKeyCredential pkhA),
      testCase "OracleSetArbiter is at constructor index 7" $
        constructorIndexOf (OracleSetArbiter scriptCred) @?= 7,
      -- APPENDED at index 4, never inserted: the four existing indices are a deployed-data contract
      -- from the first deployment, and T-ATTEST-10 is where that binds.
      testCase "OracleSetAdmin is at constructor index 4" $
        constructorIndexOf (OracleSetAdmin (PubKeyCredential pkhA)) @?= 4,
      testCase "the four inherited actions keep indices 0 to 3" $
        map constructorIndexOf inheritedActions @?= [0, 1, 2, 3],
      -- Appended at 5 for the dispute deposit, same discipline.
      testCase "OracleSetDisputeDeposit is at constructor index 5" $
        constructorIndexOf (OracleSetDisputeDeposit 5_000_000) @?= 5,
      testCase "repricing the dispute deposit changes nothing else" $
        applyOracleAdminAction (OracleSetDisputeDeposit 7_000_000) (paramsAdmin pkhA)
          @?= (paramsAdmin pkhA) {opDisputeDeposit = 7_000_000},
      -- Appended at 6 for D-A's timeout. Untested until an audit reconciliation pointed out that the
      -- action arrived with neither an index assertion nor a place in `otherActions`, so the
      -- "no other action touches the admin" test was silently not about it.
      testCase "OracleSetDisputeTimeout is at constructor index 6" $
        constructorIndexOf (OracleSetDisputeTimeout 2_592_000_000) @?= 6,
      testCase "retiming the dispute timeout changes nothing else" $
        applyOracleAdminAction (OracleSetDisputeTimeout 600_000) (paramsAdmin pkhA)
          @?= (paramsAdmin pkhA) {opDisputeTimeoutMs = 600_000},
      -- ---------------------------------------------------------------------------------------
      -- `O6` — `oracleParamsAreWellFormed`, which had NO test of any kind. It is the result-level
      -- guard every admin action passes through, so a hole in it is a hole in all seven.
      --
      -- The first case is the one that found the defect: the timeout conjunct was written `>= 0`
      -- while the comment beside it argued against exactly the class of values that contains zero.
      -- A zero timeout makes `disputeStaleAfter == disputeOpenedAt`, and `Md6` already forces
      -- `disputeOpenedAt` into the opening transaction's range, so every later range starts after it
      -- and `D9` holds — one `OracleSetDisputeTimeout 0` and no dispute can ever reach a verdict.
      testCase "a zero dispute timeout is refused, so a dispute always has a window (O6)" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opDisputeTimeoutMs = 0}) @?= False,
      testCase "a negative dispute timeout is refused (O6)" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opDisputeTimeoutMs = -1}) @?= False,
      testCase "one millisecond is well-formed: this check refuses the impossible, not the unwise" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opDisputeTimeoutMs = 1}) @?= True,
      -- The two drains the check was originally written for, and the asymmetry its Haddock claims:
      -- zero is a configuration for these two and is not one for the timeout.
      testCase "a negative minimum UTxO value is refused (O6)" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opMinUTxOValue = -5_000_000}) @?= False,
      testCase "a negative dispute deposit is refused (O6)" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opDisputeDeposit = -1}) @?= False,
      testCase "zero is accepted for the deposit and the minimum UTxO value (O6)" $
        oracleParamsAreWellFormed ((paramsAdmin pkhA) {opDisputeDeposit = 0, opMinUTxOValue = 0}) @?= True,
      -- No case here asserts that the GENESIS datum is well-formed, deliberately. `O6` is the one
      -- rule that does not run at deployment (audit OC-12), and a test that re-typed those literals
      -- would stay green while the real ones drifted. The guarantee belongs where the datum is
      -- built, so `mintOracleNFTAndLockDatum` now asserts this function itself.
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

    otherActions = inheritedActions <> [OracleSetDisputeDeposit 3_000_000, OracleSetDisputeTimeout 600_000]

    -- A script credential of the same width as a key hash, which is the point: the 28 bytes do not
    -- say which they are, so only the constructor does. That is also why the CLI asks with a flag.
    scriptCred = ScriptCredential (ScriptHash (toBuiltin (BS.replicate 28 0x5c)))

    -- Takes a key hash and wraps it, because every assertion below is about a KEY admin — the shape
    -- ADR 0005 kept byte-for-byte compatible. The script branch is a different question and
    -- `checkCredentialControl`'s own tests are where it is asked.
    paramsAdmin pkh = (paramsAdminCred (PubKeyCredential pkh)) {opArbiter = PubKeyCredential pkh}

    paramsAdminCred cred =
      OracleParams
        { opAdmin = cred,
          opPaused = False,
          opFeeConfig = Nothing,
          opMinUTxOValue = 2_000_000,
          opDisputeDeposit = 5_000_000,
          opDisputeTimeoutMs = 2_592_000_000,
          opArbiter = cred
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
