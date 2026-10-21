{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module UnitTests.Attestation
  ( attestationTests,
  )
where

import Control.Monad (void)
import Palmares.DomainTypes.Core.Actions
import Palmares.DomainTypes.Core.Types
import GHC.Stack
import GeniusYield.Test.Clb
import GeniusYield.Test.Utils
import GeniusYield.TxBuilder
import GeniusYield.Types
import Test.Fixtures (attestationProfileData, attestationProfileDataMaxLength, masterProfileData, orgProfileData, seminarProfileData, studentProfileData)
import Test.Tasty
import TestRuns (profileInteraction, deployValidators, protocolInteraction, sendDustToValidator)
import Palmares.TxBuilding.Validators (attestationsValidatorGY)

attestationTests :: (HasCallStack) => TestTree
attestationTests =
  testGroup
    "Attestation Tests"
    [ mkTestFor "Test Case 5.1: Organization issues attestation to practitioner" orgIssuesAttestationTest,
      mkTestFor "Test Case 5.2: Practitioner accepts attestation" practitionerAcceptsAttestationTest,
      mkTestFor "Test Case 5.3: Full attestation lifecycle (issue + accept)" fullAttestationLifecycleTest,
      mkTestFor "Test Case 5.4: Double-accept attestation fails (TA)" doubleAcceptAttestationFailTest,
      mkTestFor "Test Case 5.5: Wrong user cannot accept attestation" wrongUserAcceptAttestationFailTest,
      mkTestFor "Test Case 5.6: Cleanup dust at AttestationsValidator" cleanupDustAtAttestationsTest,
      mkTestFor "Issue attestation with max-length metadata succeeds" issueAttestationMaxLengthMetadataTest,
      mkTestFor "Issue attestation with other_metadata succeeds" issueAttestationWithOtherMetadataTest,
      mkTestFor "Issue attestation with reserved other_metadata key fails" issueAttestationReservedMetadataKeyFailTest
    ]
  where
    -- Test Case 5.1: Organization issues an attestation to a practitioner
    orgIssuesAttestationTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    orgIssuesAttestationTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Create Organization (w1)
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Creating Organization profile..."
      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      -- Create Practitioner (w2)
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Creating Practitioner profile..."
      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      -- Organization issues attestation to practitioner
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Organization issuing attestation..."
      s' <- slotOfCurrentBlock
      attestationDate <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX attestationDate - 1000

      (_txId, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) $ "Attestation issued: " <> show attestationAC
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Organization issues attestation test passed!"
      return ()

    issueAttestationWithOtherMetadataTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    issueAttestationWithOtherMetadataTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      s' <- slotOfCurrentBlock
      attestationDate <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX attestationDate - 1000

      void $
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [("Tournament", "Pan Ams 2024"), ("Division", "Adult Purple")],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Issue with other_metadata succeeded!"
      return ()

    issueAttestationReservedMetadataKeyFailTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    issueAttestationReservedMetadataKeyFailTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      s' <- slotOfCurrentBlock
      attestationDate <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX attestationDate - 1000

      mustFail $
        void $
          profileInteraction
            ctx
            (w1 testWallets)
            ( IssueAttestationAction
                { aa_subject_profile_id = practitionerAC,
                  aa_issuer_profile_id = orgAC,
                  aa_profile_data = attestationProfileData,
                  aa_other_metadata = [("name", "shadow")],
                  aa_attestation_date = attestationDatePast
                }
            )
            Nothing
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Reserved other_metadata key rejected as expected!"
      return ()

    issueAttestationMaxLengthMetadataTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    issueAttestationMaxLengthMetadataTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      s' <- slotOfCurrentBlock
      attestationDate <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX attestationDate - 1000

      void $
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileDataMaxLength,
                aa_other_metadata = [],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Issue attestation with max-length metadata test passed!"
      return ()

    -- Test Case 5.2: Practitioner accepts an attestation
    practitionerAcceptsAttestationTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    practitionerAcceptsAttestationTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Create Organization (w1) and Practitioner (w2)
      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      -- Organization issues attestation
      s' <- slotOfCurrentBlock
      attestationDate <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX attestationDate - 1000

      (_txId, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      waitNSlots_ 1

      -- Practitioner accepts the attestation
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Practitioner accepting attestation..."
      void $
        profileInteraction
          ctx
          (w2 testWallets)
          (AcceptAttestationAction attestationAC)
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Attestation accepted!"
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Practitioner accepts attestation test passed!"
      return ()

    -- Test Case 5.3: Full lifecycle
    fullAttestationLifecycleTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    fullAttestationLifecycleTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Create Master (w1) and Student (w2)
      (_txId, masterAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction masterProfileData Practitioner creationDate Black)
          Nothing
      waitNSlots_ 1

      (_txId, studentAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      -- Master issues two attestations to student
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "=== Issuing first attestation ==="
      s' <- slotOfCurrentBlock
      t' <- slotToBeginTime s'
      let attestationDate1 = timeFromPOSIX $ timeToPOSIX t' - 1000

      (_txId, attestation1AC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = studentAC,
                aa_issuer_profile_id = masterAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDate1
              }
          )
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "=== Issuing second attestation ==="
      s'' <- slotOfCurrentBlock
      t'' <- slotToBeginTime s''
      let attestationDate2 = timeFromPOSIX $ timeToPOSIX t'' - 1000

      (_txId, attestation2AC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = studentAC,
                aa_issuer_profile_id = masterAC,
                aa_profile_data = seminarProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDate2
              }
          )
          Nothing
      waitNSlots_ 1

      -- Student accepts both attestations
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "=== Accepting first attestation ==="
      void $
        profileInteraction
          ctx
          (w2 testWallets)
          (AcceptAttestationAction attestation1AC)
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "=== Accepting second attestation ==="
      void $
        profileInteraction
          ctx
          (w2 testWallets)
          (AcceptAttestationAction attestation2AC)
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Full attestation lifecycle test passed!"
      return ()

    -- Test Case 5.4: Double-accept attestation fails (on-chain trace TA)
    doubleAcceptAttestationFailTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    doubleAcceptAttestationFailTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Create Organization (w1) and Practitioner (w2)
      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      -- Issue attestation
      s' <- slotOfCurrentBlock
      t' <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX t' - 1000

      (_txId, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      waitNSlots_ 1

      -- First accept should succeed
      void $
        profileInteraction
          ctx
          (w2 testWallets)
          (AcceptAttestationAction attestationAC)
          Nothing
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "First accept succeeded. Attempting double-accept (should fail with TA)..."

      -- Second accept should fail with on-chain trace "TA" (already accepted)
      mustFail $
        void $
          profileInteraction
            ctx
            (w2 testWallets)
            (AcceptAttestationAction attestationAC)
            Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Double-accept attestation fail test passed!"
      return ()

    -- Test Case 5.5: Wrong user cannot accept attestation
    wrongUserAcceptAttestationFailTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    wrongUserAcceptAttestationFailTest TestInfo {..} = do
      waitNSlots_ 1000
      s <- slotOfCurrentBlock
      t <- slotToBeginTime s
      let creationDate = timeFromPOSIX $ timeToPOSIX t - 100000

      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Create Organization (w1) and Practitioner A (w2)
      (_txId, orgAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          (CreateProfileWithRankAction orgProfileData Organization creationDate White)
          Nothing
      waitNSlots_ 1

      (_txId, practitionerAC) <-
        profileInteraction
          ctx
          (w2 testWallets)
          (InitProfileAction studentProfileData Practitioner creationDate)
          Nothing
      waitNSlots_ 1

      -- Issue attestation to practitioner A (w2)
      s' <- slotOfCurrentBlock
      t' <- slotToBeginTime s'
      let attestationDatePast = timeFromPOSIX $ timeToPOSIX t' - 1000

      (_txId, attestationAC) <-
        profileInteraction
          ctx
          (w1 testWallets)
          ( IssueAttestationAction
              { aa_subject_profile_id = practitionerAC,
                aa_issuer_profile_id = orgAC,
                aa_profile_data = attestationProfileData,
                aa_other_metadata = [],
                aa_attestation_date = attestationDatePast
              }
          )
          Nothing
      waitNSlots_ 1

      -- w3 (who is NOT the subject practitioner) tries to accept -> should fail
      -- w3 does not own practitioner's User NFT, so AttestationsValidator will reject
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Wrong user (w3) attempting to accept attestation (should fail)..."
      mustFail $
        void $
          profileInteraction
            ctx
            (w3 testWallets)
            (AcceptAttestationAction attestationAC)
            Nothing

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Wrong user accept attestation fail test passed!"
      return ()

    -- Test Case 5.6: Cleanup dust at AttestationsValidator
    cleanupDustAtAttestationsTest :: (HasCallStack) => TestInfo -> GYTxMonadClb ()
    cleanupDustAtAttestationsTest TestInfo {..} = do
      waitNSlots_ 1000
      ctx <- deployValidators (w1 testWallets)
      waitNSlots_ 1000

      -- Simulate griefing: send ADA-only UTxO to attestations validator
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Sending dust UTxO to AttestationsValidator..."
      sendDustToValidator (w2 testWallets) attestationsValidatorGY
      waitNSlots_ 1

      -- Any user (w3) can clean it up — permissionless
      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Cleaning up dust via ProtocolAction CleanupDustAction..."
      _txId <- protocolInteraction ctx (w3 testWallets) CleanupDustAction
      waitNSlots_ 1

      gyLogInfo' ("TESTLOG" :: GYLogNamespace) "Dust cleanup at AttestationsValidator succeeded!"
      return ()

-- ------------------------------------------------------------------------------------------------

-- -- * Dust / Cleanup Tests

-- ------------------------------------------------------------------------------------------------
