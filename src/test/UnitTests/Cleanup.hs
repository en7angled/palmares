{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Permissionless dust cleanup, in a real ledger.
--
-- Anyone can lock ADA at a validator address. Without a sweep those UTxOs accumulate forever at
-- addresses the protocol has to enumerate, so every state validator carries a @Cleanup@ redeemer
-- that lets anyone spend a UTxO that is __not__ protocol state and keep the ADA.
--
-- The whole safety of that rests on one distinction, drawn in two places. Off chain,
-- 'Palmares.TxBuilding.Lookups.getDustUTxOs' selects only UTxOs carrying no token of the protocol's
-- policy. On chain, each validator's @Cleanup@ arm refuses any UTxO whose datum parses as its own
-- state. The inherited suite exercised the first and never the second: all five of its cases were
-- sweeps that succeeded, so @Cleanup@ could have been @const True@ and they would all have passed.
-- Test Case 3.5 is the one that fails on that.
module UnitTests.Cleanup
  ( cleanupTests,
  )
where

import Control.Monad (void)
import GHC.Stack
import GeniusYield.Test.Clb
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.Types
import Palmares.DomainTypes.Core.Actions
import Palmares.TxBuilding.Validators (attestationsValidatorGY, disputesValidatorGY, profilesValidatorGY)
import Test.Fixtures (parsingDisputeDatum)
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty
import TestRuns (deployValidators, lockParsingDatumAt, protocolInteraction, sendDustToValidator)

cleanupTests :: (HasCallStack) => TestTree
cleanupTests =
  testGroup
    "Dust Cleanup Tests"
    [ mkTestFor "Test Case 3.1: Cleanup dust at ProfilesValidator" (cleanupDustAt profilesValidatorGY),
      mkTestFor "Test Case 3.2: Cleanup dust at AttestationsValidator" (cleanupDustAt attestationsValidatorGY),
      mkTestFor "Test Case 3.3: Cleanup dust at DisputesValidator" (cleanupDustAt disputesValidatorGY),
      mkTestFor "Test Case 3.4: Cleanup dust at all three validators in a single transaction" cleanupDustEverywhere,
      mkTestFor "Test Case 3.5: Cleanup CANNOT spend a UTxO whose datum parses (D0)" cleanupRefusesParsingDatum,
      mkTestFor "Test Case 3.6: Cleanup with nothing to sweep fails off-chain (NoDustFound)" cleanupWithNoDustFails
    ]
  where
    -- One body, three validators. Each sweep is asserted by UTxO count rather than by "the
    -- transaction did not throw": the inherited version logged a success message whether or not the
    -- dust was actually gone.
    cleanupDustAt :: (HasCallStack) => GYScript 'PlutusV3 -> TestInfo -> GYTxMonadClb ()
    cleanupDustAt validator TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      before <- utxoCountAt validator
      sendDustToValidator (w2 testWallets) validator
      waitNSlots_ 1
      assert . (== before + 1) =<< utxoCountAt validator

      -- w3 sweeps, not w2 who created it and not w1 who deployed: the redeemer is permissionless and
      -- the recovered ADA goes to whoever calls.
      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1
      assert . (== before) =<< utxoCountAt validator

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Dust swept, and the address is back to where it started."

    cleanupDustEverywhere :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupDustEverywhere TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      let validators = [profilesValidatorGY, attestationsValidatorGY, disputesValidatorGY]
      befores <- mapM utxoCountAt validators
      mapM_ (sendDustToValidator (w2 testWallets)) validators
      waitNSlots_ 1

      -- ONE transaction for all three addresses, which is what `cleanupDustTX` builds and the thing
      -- that could silently sweep only the first.
      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1
      afters <- mapM utxoCountAt validators
      assert (afters == befores)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "All three addresses swept by a single transaction."

    -- THE CASE THE INHERITED SUITE DID NOT HAVE. A UTxO with a datum that parses as dispute state,
    -- and no protocol token — so the off-chain selector offers it to the sweep, and only the
    -- on-chain guard can refuse it. Delete the `Just _ -> traceError "D0"` arm and this test is the
    -- one that notices.
    --
    -- Written against the Disputes Validator because it is the one that had never executed in an
    -- emulator at all. Profiles and Attestations carry the identical guard; the stronger case for
    -- those is a sweep run beside REAL protocol state, which needs the write path (T-ATTEST-6).
    cleanupRefusesParsingDatum :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupRefusesParsingDatum TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      lockParsingDatumAt (w2 testWallets) disputesValidatorGY parsingDisputeDatum
      waitNSlots_ 1

      -- The code is ASSERTED, not just hoped for: `mustFail` alone would also pass if the sweep
      -- failed to balance, or picked nothing up, or died off-chain — which would leave the guard
      -- untested while the test went green.
      mustFailWith (failedWithTrace "D0") $ void $ protocolInteraction ctx (w3 testWallets) CleanupDustAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Cleanup refused the parsing datum (D0)."

    -- The off-chain guard, which is what stops the API from building an empty transaction every time
    -- someone pokes the cleanup endpoint.
    cleanupWithNoDustFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupWithNoDustFails TestInfo {..} = do
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1
      mustFail $ void $ protocolInteraction ctx (w3 testWallets) CleanupDustAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Cleanup with nothing to sweep was refused (NoDustFound)."

    utxoCountAt :: (GYTxQueryMonad m) => GYScript 'PlutusV3 -> m Int
    utxoCountAt validator = do
      addr <- scriptAddress validator
      length . utxosToList <$> utxosAtAddresses [addr]
