{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the chain-sync replay/rollback ordering (F-02/F-05/F-07) and for the Kupo
-- value conversion the projection depends on. The classify + deletion-sequencing cases drove
-- the rank datums; they come back with the new projections.
module UnitTests.ChainSyncReplay (chainSyncReplayTests) where

import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.Map qualified as Map
import GeniusYield.Types
  ( GYAddress,
    GYNetworkId (GYTestnetPreview),
    GYOutDatum (GYOutDatumInline),
    addressFromScriptHash,
    datumFromPlutusData,
    unsafeSlotFromInteger,
    valueFromLovelace,
  )
import Palmares.ChainSync.KupoAtlas (AtlasMatch (..), toGYAssetClass)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..), KupoValue (..))
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusTx.Builtins (toBuiltin)
import Palmares.Storage
  ( OnchainMatchEvent (..),
    onchainMatchEventCreatedOutputIndex,
    onchainMatchEventCreatedSlot,
    onchainMatchEventCreatedTxIndex,
    replayOrder,
  )
import Test.Tasty
import Test.Tasty.HUnit

-- A raw match whose Kupo payload is irrelevant to ordering.
dummyMatch :: KupoMatch
dummyMatch =
  KupoMatch
    { transaction_index = 0,
      transaction_id = "tx",
      output_index = 0,
      address = "addr",
      value = KupoValue 0 Map.empty,
      datum_hash = Nothing,
      datum_type = Nothing,
      datum = Nothing,
      script_hash = Nothing,
      created_at = CreatedAt 0 "h",
      spent_at = Nothing
    }

ev :: Integer -> Int -> Int -> OnchainMatchEvent
ev slot txIx outIx = OnchainMatchEvent slot "hdr" "tx" txIx outIx dummyMatch

valueConversionTests :: TestTree
valueConversionTests =
  testGroup
    "Kupo asset conversion (F-06)"
    [ testCase "dotted policyId.assetName parses" $
        isRight (toGYAssetClass "00000000000000000000000000000000000000000000000000000000.6162") @?= True,
      testCase "dotless empty-name policyId parses instead of crashing" $
        isRight (toGYAssetClass "00000000000000000000000000000000000000000000000000000000") @?= True,
      testCase "garbage returns Left, not a crash" $
        isLeft (toGYAssetClass "xyz") @?= True
    ]

------------------------------------------------------------------------------------------------
-- Fixtures for the classify + deletion-sequencing tests (F-33 item 2 and 3, design spec §7).
--
-- These drive the REAL 'projectChainEvent' (Ingestion.hs) on synthetic 'AtlasMatch' values, at
-- no DB and no live provider: 'projectChainEvent' is 'MonadError GYTxMonadException'-polymorphic
-- and depends only on a 'GYNetworkId' and pure validator-hash constants, so it runs purely via
-- 'runExceptT'. Both a 'Rank' and a 'Promotion' onchain datum decode at the ranks-validator
-- address (see 'rankFromGYOutDatum' / TxBuilding.Utils) as a *bare* 'OnchainRank' — no CIP-68
-- wrapper — so no ambiguous metadata map is needed to build a valid fixture.
------------------------------------------------------------------------------------------------

-- | Test-only network id; the specific choice does not matter as long as it's used consistently
-- to both build the fixture address and to invoke 'projectChainEvent'.
testNetworkId :: GYNetworkId
testNetworkId = GYTestnetPreview

chainSyncReplayTests :: TestTree
chainSyncReplayTests =
  testGroup
    "Chain-sync replay ordering"
    [ testCase "sorts across the 8-digit/9-digit slot boundary numerically (F-02)" $
        map onchainMatchEventCreatedSlot (replayOrder [ev 100000000 0 0, ev 99999999 0 0])
          @?= [99999999, 100000000],
      testCase "same-block matches ordered by (txIndex, outputIndex); all retained (F-05/F-07)" $
        map (\e -> (onchainMatchEventCreatedTxIndex e, onchainMatchEventCreatedOutputIndex e))
          (replayOrder [ev 5 2 0, ev 5 1 3, ev 5 1 0])
          @?= [(1, 0), (1, 3), (2, 0)],
      valueConversionTests
    ]
