{-# LANGUAGE OverloadedStrings #-}

module UnitTests where

import GHC.Stack
import Test.Tasty
import UnitTests.Activity qualified as Activity
import UnitTests.Anchor qualified as Anchor
import UnitTests.ApiHardening (apiHardeningTests)
import UnitTests.ChainSyncReplay (chainSyncReplayTests)
import UnitTests.Conversions (conversionsTests)
import UnitTests.GovDto (govDtoTests)
import UnitTests.GovIds (govIdsTests)
import UnitTests.GovThresholds (govThresholdsTests)
import UnitTests.MetricCatalog qualified as MetricCatalog
import UnitTests.MetricDoc qualified as MetricDoc
import UnitTests.MetricFixture qualified as MetricFixture
import UnitTests.ApplySql qualified as ApplySqlTests
import UnitTests.AttestSchema qualified as AttestSchema
import UnitTests.QueryHardening (queryHardeningTests)
import UnitTests.Reconcile (reconcileTests)
import UnitTests.Refresh qualified as Refresh
import UnitTests.StorageRoundtrip (storageRoundtripTests)
import UnitTests.ThresholdMap qualified as ThresholdMap
import UnitTests.Views qualified as Views

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
      MetricCatalog.tests,
      MetricDoc.tests,
      MetricFixture.tests,
      queryHardeningTests,
      ApplySqlTests.tests,
      AttestSchema.tests,
      reconcileTests,
      Refresh.tests,
      storageRoundtripTests,
      ThresholdMap.tests,
      Views.tests
    ]
