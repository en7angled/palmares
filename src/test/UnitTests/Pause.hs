{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The pause, asserted ON CHAIN: @opPaused@ stops writes, and housekeeping keeps running.
--
-- __Why this module exists beside @UnitTests.Attestation@'s @pauseStopsEverything@.__ That case
-- pauses the protocol and watches an update, an acceptance and an issuance fail, and it is correct as
-- far as it goes — but it uses a bare 'mustFail', because what refuses those transactions is
-- 'Palmares.TxBuilding.Operations.getOracleRefInputSkeleton' throwing @ProtocolPaused@ at
-- skeleton-BUILD time, before any script runs. An off-chain refusal is a courtesy to a client, not a
-- protocol rule: anyone who builds their own transaction never calls it. Until the validators read
-- @opPaused@ themselves, a paused protocol could still have an existing profile rewritten and an open
-- dispute settled by hand, and that case would have gone on passing.
--
-- So every negative case here uses @mustFailWith (failedWithTrace …)@ and names the code, which is
-- the only assertion that distinguishes "the chain refused this" from "something went wrong".
--
-- __The pause covers writes, not reads, and not the sweep.__ @Cleanup@ is permissionless
-- housekeeping that moves no protocol state — after the value-backed guard it provably cannot, see
-- 'Palmares.Onchain.Utils.isUnbackedDatum' — so gating it would hand an admin the power to freeze the
-- dust sweep while the clutter accumulates. Test Case 7.3 pins that it still runs.
--
-- __The acceptance is here now, and it was the one that mattered.__ This module used to record its
-- absence: 'Palmares.Onchain.Protocol.Types.OnchainAttestation' carried no route to the oracle, so
-- the validator could not read @opPaused@ at all, and acceptance was __the only write the pause did
-- not reach__ — while also being irreversible, which is the conjunction that made it urgent. (Not
-- the protocol's ONLY irreversible write: a verdict is written once and nothing here burns.)
--
-- Two routes out of it existed and this header used to name them: a new datum field, or requiring
-- the subject's profile as a second reference input on every acceptance. The owner took the datum
-- field (D-C), the one that leaves the transaction every honest client builds unchanged;
-- 'Palmares.Onchain.Protocol.Types.attestationOracleToken' is the field and @A7@ is the check. Test
-- Case 7.4 asserts it ON CHAIN, which is the half @pauseStopsEverything@ cannot reach.
module UnitTests.Pause
  ( pauseTests,
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
import Palmares.TxBuilding.Context (DeployedScriptsContext)
import Palmares.TxBuilding.Validators (profilesValidatorGY)
import Test.Fixtures (disputeStatementData, drepProfileData, milestoneAttestationData, orgProfileData)
import Test.Helpers (assert, failedWithTrace)
import Test.Tasty
import TestRuns
  ( adminInteraction,
    deployValidators,
    disputeInteraction,
    maliciousAcceptWhilePaused,
    maliciousUpdateProfile,
    profileInteraction,
    protocolInteraction,
    sendDustToValidator,
  )

pauseTests :: (HasCallStack) => TestTree
pauseTests =
  testGroup
    "Pause Tests"
    [ mkTestFor "Test Case 7.1: a paused protocol refuses a profile update ON CHAIN (P6)" pausedUpdateRefused,
      mkTestFor "Test Case 7.2: a paused protocol refuses a dispute resolution ON CHAIN (D7)" pausedResolutionRefused,
      mkTestFor "Test Case 7.3: the dust sweep still runs while paused" pausedSweepStillRuns,
      mkTestFor "Test Case 7.4: a paused protocol refuses an attestation acceptance ON CHAIN (A7)" pausedAcceptanceRefused
    ]
  where
    -- Test Case 7.1. Two transactions from the SAME builder, and the first one is the half that makes
    -- the second mean anything: unpaused it must succeed, so @P6@ cannot be a check that refuses
    -- everything. Without it, `traceIfFalse "P6" False` would pass this test.
    pausedUpdateRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pausedUpdateRefused TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000
      (_t1, profileAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Domain.Organization orgProfileData)
          Nothing
      waitNSlots_ 1

      _unpausedTxId <- maliciousUpdateProfile ctx (w1 testWallets) profileAC "ipfs://QmBeforeThePause"
      waitNSlots_ 1

      -- w1 deployed, so w1 is the oracle admin: see 'TestRuns.initialOracleParamsFor'.
      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      mustFailWith (failedWithTrace "P6") $
        void $
          maliciousUpdateProfile ctx (w1 testWallets) profileAC "ipfs://QmWhilePaused"

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A paused protocol refused a hand-built profile update (P6)."

    -- Test Case 7.2. A verdict is irreversible (@D3@) and a dispute is cheap and repeatable, so a
    -- pause that stopped the opening and left the settling running had the two exactly the wrong way
    -- round. @D7@ closed that on chain.
    --
    -- __THE REFUSAL MOVED OFF CHAIN WITH `OF-03`.__ This case used to assert `failedWithTrace "D7"`
    -- and said so deliberately: "it needs NO malicious builder […] 'resolveDisputeTX' reads the
    -- oracle directly rather than through @getOracleRefInputSkeleton@, so the production path still
    -- BUILDS a resolution while paused and the validator is what refuses it."
    --
    -- Reading the oracle directly is exactly why the fix was one line: the builder HAD the paused
    -- flag and did not look at it. This was the last write path that handed back a transaction the
    -- chain was certain to reject, so the arbiter found out as a script failure after signing instead
    -- of as a 503 before. @D7@ still exists and the chain is still the authority; the test no longer
    -- names a trace code because the production path no longer reaches one.
    pausedResolutionRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pausedResolutionRefused info@TestInfo {..} = do
      (ctx, _attestationAC, disputeAC) <- deployWithOpenDispute info

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      mustFail $
        void $
          disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC Domain.VerdictUpheld)

      -- The half that makes the refusal mean something, the same rule 7.1 follows: unpaused it must
      -- SUCCEED, or a guard that refused everything would pass this test.
      _ <- adminInteraction ctx (w1 testWallets) UnpauseProtocolAction
      waitNSlots_ 1
      _ <- disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC Domain.VerdictUpheld)
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A paused protocol refused a dispute resolution off-chain, and allowed it once unpaused."

    -- Test Case 7.3. The sweep is permissionless housekeeping and must survive a pause: it moves no
    -- protocol state, and an admin who could freeze it could let griefing dust pile up at every state
    -- address with no way for anyone to clear it. Asserted by UTxO count rather than by "the
    -- transaction did not throw", which would also hold for a sweep that picked nothing up.
    pausedSweepStillRuns :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pausedSweepStillRuns TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      before <- utxoCountAt profilesValidatorGY
      sendDustToValidator (w2 testWallets) profilesValidatorGY
      waitNSlots_ 1
      assert . (== before + 1) =<< utxoCountAt profilesValidatorGY

      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1
      assert . (== before) =<< utxoCountAt profilesValidatorGY

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "The dust sweep ran while the protocol was paused."

    -- Test Case 7.4 — D-C, and the reason it was taken before the first deploy rather than after:
    -- acceptance is irreversible AND was the only write the pause did not reach, so a pause during
    -- an incident still let acceptances land for good.
    --
    -- The order is pause-then-unpause, not 7.1's unpause-then-pause, and the reason is that an
    -- acceptance cannot be repeated: there is one of them, so it has to serve as the negative half
    -- first and the positive control after. Run the other way round, the negative half would be a
    -- SECOND acceptance of an already-accepted attestation, which @A3@ refuses whether or not @A7@
    -- exists — so it could distinguish nothing.
    --
    -- Two earlier claims in this comment were wrong and are worth leaving corrected. "The second
    -- one would die on @A3@" describes the old code: @A7@ now precedes @A3@ in the chain and
    -- PlutusTx's @&&@ is lazy, so a paused re-acceptance dies on @A7@ and @A3@ is never reached.
    -- And "the other way round this test would pass with @traceIfFalse \"A7\" False@" is backwards
    -- — in that order the unpaused acceptance comes FIRST and unguarded, so an always-false @A7@
    -- would make it throw and the test would fail. The mutation guard is 7.1's positive control,
    -- not the ordering.
    pausedAcceptanceRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pausedAcceptanceRefused info@TestInfo {..} = do
      (ctx, attestationAC, _disputeAC) <- deployWithOpenDispute info

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      -- w2 is the subject, so @A5@ is satisfied and the pause is the only thing left to refuse it.
      mustFailWith (failedWithTrace "A7") $
        void $
          maliciousAcceptWhilePaused ctx (w2 testWallets) attestationAC

      _ <- adminInteraction ctx (w1 testWallets) UnpauseProtocolAction
      waitNSlots_ 1
      _txId <- maliciousAcceptWhilePaused ctx (w2 testWallets) attestationAC
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A paused protocol refused an attestation acceptance (A7), and allowed it once unpaused."

    -- Deploy, give w1 an organisation and w2 a DRep person, issue an attestation about w2 and have w2
    -- open a dispute against it. The attestation is deliberately left UNACCEPTED, which is what Test
    -- Case 7.4 needs: it is the write that 7.4 then tries to make while paused.
    deployWithOpenDispute ::
      (HasCallStack) => TestInfo -> GYTxMonadClb (DeployedScriptsContext, GYAssetClass, GYAssetClass)
    deployWithOpenDispute TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000
      (_t1, issuerAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (ClaimProfileAction Domain.Organization orgProfileData)
          Nothing
      waitNSlots_ 1
      (_t2, subjectAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (ClaimProfileAction Domain.PersonDRep drepProfileData)
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
      return (ctx, attestationAC, disputeAC)

    utxoCountAt :: (GYTxQueryMonad m) => GYScript 'PlutusV3 -> m Int
    utxoCountAt validator = do
      addr <- scriptAddress validator
      length . utxosToList <$> utxosAtAddresses [addr]
