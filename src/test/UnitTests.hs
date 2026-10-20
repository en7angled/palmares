{-# LANGUAGE OverloadedStrings #-}

module UnitTests where

import GHC.Stack
import Test.Tasty
import UnitTests.Activity qualified as Activity
import UnitTests.Anchor qualified as Anchor
import UnitTests.ApiHardening (apiHardeningTests)
import UnitTests.ChainSyncReplay (chainSyncReplayTests)
import UnitTests.Conversions (conversionsTests)
import UnitTests.GovIds (govIdsTests)
import UnitTests.MetricCatalog qualified as MetricCatalog
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
      govIdsTests,
      MetricCatalog.tests,
      storageRoundtripTests,
      ThresholdMap.tests,
      Views.tests
    ]
