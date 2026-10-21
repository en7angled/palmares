{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What each validator costs to put on chain.
--
-- __The gap this closes.__ @TxBuilding.Validators@ has exported @profilesValidatorSize@ and its four
-- siblings since the first commit and nothing ever called them. The only place a size was ever
-- reported was a log line in @TestRuns.deployValidators@ — printed, never asserted, and for the
-- whole stretch while the emulator suite was dormant, never even printed. So a change that doubled a
-- script was indistinguishable from one that did not, right up to the deployment that paid for it.
--
-- __Two assertions, because they catch different things.__ The ceiling is correctness: a reference
-- script has to fit in a transaction, and one that does not cannot be deployed at all. The exact
-- table is economics: a validator that grew 30% still deploys, still passes every other test, and
-- quietly raises the min-ADA of every UTxO that references it. Pinning the number is what makes that
-- growth a visible diff instead of an invoice. When a change is meant to move a size, the table is
-- updated in the same commit — that update IS the record.
module UnitTests.ScriptSize (tests) where

import Palmares.TxBuilding.Validators
  ( attestationsValidatorSize,
    disputesValidatorSize,
    mintingPolicySize,
    oracleValidatorSize,
    profilesValidatorSize,
  )
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "script sizes"
    [ -- The whole table in one assertion, so a failure prints every size rather than the first one
      -- that moved. Flat-encoded bytes, which is what goes in the reference-script output.
      testCase "every validator is exactly the size it was when this was last reviewed" $
        assertEqual "a validator changed size — update the table in the same commit, deliberately" expected measured,
      -- The hard limit. `maxTxSize` is 16384 bytes, and the transaction that deploys a reference
      -- script carries the script PLUS its own inputs, outputs, change and witnesses. 14000 leaves
      -- about 2.4 KB for all of that, which is the margin `deployValidators` actually runs in.
      --
      -- The MintingPolicy is the one to watch: at 11850 bytes it is 72% of a whole transaction, and
      -- it is the only script that grows when a redeemer case is added. The four spending validators
      -- sit near 7.5 KB each and have room.
      testCase "every validator leaves room for the transaction that deploys it" $
        filter ((> 14_000) . snd) measured @?= []
    ]

-- | Measured sizes, by name. The minting policy is parameterised, so it is measured against the same
-- placeholder oracle token the blueprint uses — a real deployment's 28-byte currency symbol adds a
-- few bytes to this figure and nothing structural.
measured :: [(String, Int)]
measured =
  [ ("ProfilesValidator", profilesValidatorSize),
    ("AttestationsValidator", attestationsValidatorSize),
    ("DisputesValidator", disputesValidatorSize),
    ("OracleValidator", oracleValidatorSize),
    ("MintingPolicy", mintingPolicySize placeholderOracleToken)
  ]
  where
    placeholderOracleToken = AssetClass (CurrencySymbol "", TokenName "")

-- | Measured on 2026-10-21, GHC 9.6.6 with the frozen plutus-tx, at the end of Plan B's Phase 2
-- (five validators, disputes included) and with traces preserved — which is the default build and
-- therefore the one that gets deployed. A toolchain bump moves all five at once and is the one case
-- where updating this table wholesale is the right response.
--
-- With traces stripped the same five measured 7707, 7410, 8032, 7293, 11482 — taken before the
-- critical fix below, and not re-measured since, because the option to strip them is gone. Traces
-- cost between 1.8% and 3.4%, which is what made keeping them an easy decision.
--
-- The minting policy last moved 11871 -> 11850 when the audit's critical finding was fixed: deleting
-- the staking-half disjunct from 'checkCredentialControl' removed one comparison. That the other
-- four did not move is the useful part of this table — it says the change reached only the script
-- that calls that function, which is what a surgical fix looks like.
expected :: [(String, Int)]
expected =
  [ ("ProfilesValidator", 7879),
    ("AttestationsValidator", 7554),
    ("DisputesValidator", 8243),
    ("OracleValidator", 7427),
    ("MintingPolicy", 11850)
  ]
