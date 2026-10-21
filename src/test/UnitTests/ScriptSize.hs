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
        assertEqual "if this fails under -f preserve-logging, that is expected: traces cost bytes" expected measured,
      -- The hard limit. `maxTxSize` is 16384 bytes, and the transaction that deploys a reference
      -- script carries the script PLUS its own inputs, outputs, change and witnesses. 14000 leaves
      -- about 2.4 KB for all of that, which is the margin `deployValidators` actually runs in.
      --
      -- The MintingPolicy is the one to watch: at 11482 bytes it is 70% of a whole transaction, and
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
-- (five validators, disputes included). A toolchain bump moves all five at once and is the one case
-- where updating this table wholesale is the right response.
expected :: [(String, Int)]
expected =
  [ ("ProfilesValidator", 7707),
    ("AttestationsValidator", 7410),
    ("DisputesValidator", 8032),
    ("OracleValidator", 7293),
    ("MintingPolicy", 11482)
  ]
