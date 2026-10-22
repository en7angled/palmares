{-# LANGUAGE OverloadedStrings #-}

module UnitTests where

import GHC.Stack
import Test.Tasty
import UnitTests.Activity qualified as Activity
import UnitTests.Anchor qualified as Anchor
import UnitTests.AttestRead (attestReadTests)
import UnitTests.Blueprint qualified as Blueprint
import UnitTests.Attestation (attestationTests)
import UnitTests.ApiHardening (apiHardeningTests)
import UnitTests.ChainSyncReplay (chainSyncReplayTests)
import UnitTests.Conversions (conversionsTests)
import UnitTests.GovDto (govDtoTests)
import UnitTests.GovIds (govIdsTests)
import UnitTests.GovThresholds (govThresholdsTests)
import UnitTests.InteractionApi (interactionApiTests)
import UnitTests.MetadataLimits qualified as MetadataLimits
import UnitTests.MintInputs qualified as MintInputs
import UnitTests.MutationGuards qualified as MutationGuards
import UnitTests.MetricCatalog qualified as MetricCatalog
import UnitTests.MetricDoc qualified as MetricDoc
import PropertyTests (propertyTests)
import UnitTests.MetricFixture qualified as MetricFixture
import UnitTests.ApplySql qualified as ApplySqlTests
import UnitTests.Cleanup (cleanupTests)
import UnitTests.Pause (pauseTests)
import UnitTests.Oracle (oracleTests)
import UnitTests.ScriptSize qualified as ScriptSize
import UnitTests.AttestSchema qualified as AttestSchema
import UnitTests.Claim qualified as Claim
import UnitTests.Dispute qualified as Dispute
import UnitTests.Fees qualified as Fees
import UnitTests.OracleRules qualified as OracleRules
import UnitTests.Projections qualified as Projections
import UnitTests.Profile (profileTests)
import UnitTests.QueryHardening (queryHardeningTests)
import UnitTests.Reconcile (reconcileTests)
import UnitTests.Refresh qualified as Refresh
import UnitTests.Satisfaction qualified as Satisfaction
import UnitTests.StorageRoundtrip (storageRoundtripTests)
import UnitTests.ThresholdMap qualified as ThresholdMap
import UnitTests.Views qualified as Views
import UnitTests.WritePath (writePathTests)

unitTests :: (HasCallStack) => TestTree
unitTests =
  testGroup
    "Unit Tests"
    [ Activity.tests,
      Anchor.tests,
      apiHardeningTests,
      chainSyncReplayTests,
      conversionsTests,
      govDtoTests,
      govIdsTests,
      govThresholdsTests,
      interactionApiTests,
      MetricCatalog.tests,
      MetricDoc.tests,
      MetricFixture.tests,
      queryHardeningTests,
      ApplySqlTests.tests,
      AttestSchema.tests,
      Claim.tests,
      Satisfaction.tests,
      MintInputs.tests,
      MutationGuards.tests,
      MetadataLimits.tests,
      Blueprint.tests,
      attestReadTests,
      Dispute.tests,
      Fees.tests,
      OracleRules.tests,
      Projections.tests,
      propertyTests,
      reconcileTests,
      Refresh.tests,
      ScriptSize.tests,
      storageRoundtripTests,
      ThresholdMap.tests,
      Views.tests,
      writePathTests,
      -- The emulator groups last: every case in them deploys a protocol into a fresh CLB ledger, so
      -- they are the slow part of the suite and a failure is easier to read at the bottom.
      cleanupTests,
      pauseTests,
      oracleTests,
      attestationTests,
      profileTests,
      Dispute.disputeEmulatorTests
    ]
