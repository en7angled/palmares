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
-- __What is NOT here: the attestation acceptance.__ 'Palmares.Onchain.Validators.AttestationsValidator'
-- gained no pause check, because an attestation datum carries no route to the oracle: the Profiles
-- Validator reads the token out of its profile's @protocolParams@ and the Disputes Validator out of
-- @disputeOracleToken@, while 'Palmares.Onchain.Protocol.Types.OnchainAttestation' has neither. The
-- routes that exist are a new datum field (which changes the minting policy and the deployed datum
-- format) or requiring the subject's profile as a second reference input on every acceptance (which
-- changes the transaction every honest client builds). Both are protocol changes rather than a fix,
-- and acceptance stays off-chain-only-paused until one is decided. @pauseStopsEverything@ still
-- covers that half.
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
      mkTestFor "Test Case 7.3: the dust sweep still runs while paused" pausedSweepStillRuns
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
          (ClaimProfileAction Domain.Organization Nothing Nothing orgProfileData)
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

    -- Test Case 7.2, and it needs NO malicious builder, which is the honest statement of what changed:
    -- 'Palmares.TxBuilding.Operations.resolveDisputeTX' reads the oracle directly rather than through
    -- @getOracleRefInputSkeleton@, so the production path still BUILDS a resolution while paused and
    -- the validator is what refuses it. The admin signs, the dispute is open, so @D1@ and @D3@ pass
    -- and @D7@ is the only thing left to say no.
    --
    -- A verdict is irreversible (@D3@) and a dispute is cheap and repeatable, so a pause that stopped
    -- the opening and left the settling running had the two exactly the wrong way round.
    pausedResolutionRefused :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    pausedResolutionRefused info@TestInfo {..} = do
      (ctx, disputeAC) <- deployWithOpenDispute info

      _ <- adminInteraction ctx (w1 testWallets) PauseProtocolAction
      waitNSlots_ 1

      mustFailWith (failedWithTrace "D7") $
        void $
          disputeInteraction ctx (w1 testWallets) (ResolveDisputeAction disputeAC Domain.VerdictUpheld)

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "A paused protocol refused a dispute resolution (D7)."

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

    -- Deploy, give w1 an organisation and w2 a DRep person, issue an attestation about w2 and have w2
    -- open a dispute against it. The attestation is deliberately NOT accepted: acceptance is the one
    -- write this commit leaves unpaused on chain (see the module header), so making the fixture depend
    -- on it would couple this module to the half that did not change.
    deployWithOpenDispute ::
      (HasCallStack) => TestInfo -> GYTxMonadClb (DeployedScriptsContext, GYAssetClass)
    deployWithOpenDispute TestInfo {..} = do
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
      return (ctx, disputeAC)

    utxoCountAt :: (GYTxQueryMonad m) => GYScript 'PlutusV3 -> m Int
    utxoCountAt validator = do
      addr <- scriptAddress validator
      length . utxosToList <$> utxosAtAddresses [addr]
