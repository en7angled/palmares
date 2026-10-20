{-# LANGUAGE OverloadedStrings #-}

module UnitTests where

import GHC.Stack
import Test.Tasty
import UnitTests.Anchor qualified as Anchor
import UnitTests.ApiHardening (apiHardeningTests)
import UnitTests.ChainSyncReplay (chainSyncReplayTests)
import UnitTests.Conversions (conversionsTests)
import UnitTests.GovIds (govIdsTests)
import UnitTests.StorageRoundtrip (storageRoundtripTests)
import UnitTests.Views qualified as Views

unitTests :: (HasCallStack) => TestTree
unitTests =
  testGroup
    "Unit Tests"
    [ Anchor.tests,
      apiHardeningTests,
      chainSyncReplayTests,
      conversionsTests,
      govIdsTests,
      storageRoundtripTests,
      Views.tests
    ]
