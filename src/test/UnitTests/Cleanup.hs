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
-- policy. On chain, each validator's @Cleanup@ arm refuses any UTxO whose own VALUE backs the state
-- NFT its datum names. The inherited suite exercised the first and never the second: all five of its
-- cases were sweeps that succeeded, so @Cleanup@ could have been @const True@ and they would all have
-- passed. Test Case 3.7 is the one that fails on that.
--
-- __Test Case 3.5 asserts the opposite of what it used to__, and the inversion is the fix rather than
-- a loosened test. The on-chain arm used to refuse a UTxO whose datum merely PARSED, which made
-- "parses as my state" mean "is my state" — so anyone could park a min-ADA UTxO carrying a
-- hand-written datum at a state address and nobody could ever sweep it, because nothing in this
-- protocol burns. A datum no NFT backs is now dust, which is what 3.5 now sweeps; a datum an NFT
-- backs is state, which is what 3.7 proves is still refused. See
-- 'Palmares.Onchain.Utils.isUnbackedDatum'.
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
import Palmares.DomainTypes.Core.Types qualified as Domain
import Palmares.Onchain.Validators.AttestationsValidator qualified as AttestationsValidator (AttestationsRedeemer (Cleanup))
import Palmares.Onchain.Validators.DisputesValidator qualified as DisputesValidator (DisputesRedeemer (Cleanup))
import Palmares.Onchain.Validators.ProfilesValidator qualified as ProfilesValidator (ProfilesRedeemer (Cleanup))
import Palmares.TxBuilding.Context
  ( DeployedScriptsContext,
    getAttestationsValidatorRef,
    getDisputesValidatorRef,
    getProfilesValidatorRef,
  )
import Palmares.TxBuilding.Validators (attestationsValidatorGY, disputesValidatorGY, profilesValidatorGY)
import Test.Fixtures (disputeStatementData, drepProfileData, milestoneAttestationData, orgProfileData, parsingDisputeDatum)
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty
import TestRuns
  ( deployValidators,
    disputeInteraction,
    lockParsingDatumAt,
    maliciousCleanupState,
    profileInteraction,
    protocolInteraction,
    sendDustToValidator,
  )

cleanupTests :: (HasCallStack) => TestTree
cleanupTests =
  testGroup
    "Dust Cleanup Tests"
    [ mkTestFor "Test Case 3.1: Cleanup dust at ProfilesValidator" (cleanupDustAt profilesValidatorGY),
      mkTestFor "Test Case 3.2: Cleanup dust at AttestationsValidator" (cleanupDustAt attestationsValidatorGY),
      mkTestFor "Test Case 3.3: Cleanup dust at DisputesValidator" (cleanupDustAt disputesValidatorGY),
      mkTestFor "Test Case 3.4: Cleanup dust at all three validators in a single transaction" cleanupDustEverywhere,
      mkTestFor "Test Case 3.5: Cleanup CAN spend a parsing datum that no NFT backs" cleanupSweepsUnbackedDatum,
      mkTestFor "Test Case 3.6: Cleanup with nothing to sweep fails off-chain (NoDustFound)" cleanupWithNoDustFails,
      mkTestFor "Test Case 3.7: Cleanup CANNOT spend real protocol state (P0/A0/D0)" cleanupRefusesRealState
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

    -- THE GRIEFING CASE, and the one that fails on the old behaviour. A UTxO with a datum that parses
    -- as dispute state and no protocol token: the off-chain selector offers it to the sweep, and the
    -- on-chain arm used to refuse it with @D0@ because its datum parsed. Nothing in this protocol
    -- burns, so that refusal was permanent — a few ADA bought a row nobody could ever remove from
    -- every scan of the Disputes address. A datum no NFT backs is dust, and this is the sweep that
    -- proves it.
    --
    -- Written against the Disputes Validator because its fixture is the cheapest thing that reaches
    -- the branch at all; the backed direction is Test Case 3.7, at all three validators.
    cleanupSweepsUnbackedDatum :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupSweepsUnbackedDatum TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      before <- utxoCountAt disputesValidatorGY
      lockParsingDatumAt (w2 testWallets) disputesValidatorGY parsingDisputeDatum
      waitNSlots_ 1
      assert . (== before + 1) =<< utxoCountAt disputesValidatorGY

      -- Counted, not merely "the transaction did not throw": a sweep that built, balanced and picked
      -- nothing up would otherwise pass.
      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1
      assert . (== before) =<< utxoCountAt disputesValidatorGY

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A parsing datum that no NFT backs was swept as dust."

    -- The off-chain guard, which is what stops the API from building an empty transaction every time
    -- someone pokes the cleanup endpoint.
    cleanupWithNoDustFails :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupWithNoDustFails TestInfo {..} = do
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1
      mustFail $ void $ protocolInteraction ctx (w3 testWallets) CleanupDustAction
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Cleanup with nothing to sweep was refused (NoDustFound)."

    -- Test Case 3.7. THE CASE THE INHERITED SUITE COULD NOT HAVE: `getDustUTxOs` never offers a UTxO
    -- carrying a protocol token, so no sweep the API can build puts real state in front of a
    -- @Cleanup@ arm, and all five inherited cases would have passed with the arm deleted.
    -- 'TestRuns.maliciousCleanupState' is the hand-built transaction that does, and what it would
    -- take is the state NFT itself plus its min-ADA, into the sweeper's change.
    --
    -- Three validators and not one, because these are three different checks: each reads its own
    -- datum field, all three fields are an @AssetClass@, and @disputeTarget@ in place of @disputeId@
    -- would type-check and point at an attestation that lives at another address.
    cleanupRefusesRealState :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupRefusesRealState info@TestInfo {..} = do
      (ctx, profileAC, attestationAC, disputeAC) <- deployWithStateEverywhere info
      -- w3 holds no profile and sweeps nothing of its own: @Cleanup@ takes no authority, so the only
      -- thing that can stop it is the value-backed guard.
      let sweeper = w3 testWallets

      mustFailWith (failedWithTrace "P0") $
        void $
          maliciousCleanupState
            ctx
            sweeper
            getProfilesValidatorRef
            profilesValidatorGY
            (redeemerFromPlutusData ProfilesValidator.Cleanup)
            profileAC
      mustFailWith (failedWithTrace "A0") $
        void $
          maliciousCleanupState
            ctx
            sweeper
            getAttestationsValidatorRef
            attestationsValidatorGY
            (redeemerFromPlutusData AttestationsValidator.Cleanup)
            attestationAC
      mustFailWith (failedWithTrace "D0") $
        void $
          maliciousCleanupState
            ctx
            sweeper
            getDisputesValidatorRef
            disputesValidatorGY
            (redeemerFromPlutusData DisputesValidator.Cleanup)
            disputeAC

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Real state at all three validators refused the sweep (P0/A0/D0)."

    -- One live UTxO at each of the three state addresses: a profile, an attestation about a second
    -- profile, and a dispute against that attestation. The attestation is deliberately NOT accepted —
    -- acceptance changes a datum field no @Cleanup@ arm reads, and skipping it is one transaction
    -- fewer in a helper that already runs a deployment and four interactions.
    deployWithStateEverywhere ::
      (HasCallStack) =>
      TestInfo ->
      GYTxMonadClb (DeployedScriptsContext, GYAssetClass, GYAssetClass, GYAssetClass)
    deployWithStateEverywhere TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000
      (_t1, issuerAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Domain.Organization Nothing Nothing orgProfileData)
          Nothing
      waitNSlots_ 1
      (_t2, subjectAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (ClaimProfileAction Domain.PersonDRep Nothing Nothing drepProfileData)
          Nothing
      waitNSlots_ 1
      (_t3, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = subjectAC,
                aa_issuer_profile_id = issuerAC,
                aa_kind = Domain.MilestoneDelivered,
                aa_profile_data = milestoneAttestationData,
                aa_other_metadata = [],
                aa_claimed_period = Nothing
              }
          )
          Nothing
      waitNSlots_ 1
      (_t4, disputeAC) <-
        disputeInteraction
          ctx
          (w2 testWallets)
          ( OpenDisputeAction
              { od_attestation_id = attestationAC,
                od_opened_by_profile_id = subjectAC,
                od_deposit_to = Nothing,
                od_profile_data = disputeStatementData
              }
          )
      waitNSlots_ 1
      return (ctx, issuerAC, attestationAC, disputeAC)

    utxoCountAt :: (GYTxQueryMonad m) => GYScript 'PlutusV3 -> m Int
    utxoCountAt validator = do
      addr <- scriptAddress validator
      length . utxosToList <$> utxosAtAddresses [addr]
