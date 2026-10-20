{-# LANGUAGE OverloadedStrings #-}

-- | Pure tests for the chain-sync replay/rollback ordering (F-02/F-05/F-07), the Kupo value
-- conversion the projection depends on (F-06), and the state-UTxO authentication guard
-- (inherited fix #3). The classify + deletion-sequencing cases drove the rank datums; they come
-- back with the new projections.
module UnitTests.ChainSyncReplay (chainSyncReplayTests) where

import Data.Either (isLeft, isRight)
import Data.Map qualified as Map
import Data.Text (Text)
import GeniusYield.Types
  ( GYAssetClass (GYLovelace),
    GYMintingPolicyId,
    valueFromLovelace,
    valueSingleton,
  )
import Palmares.ChainSync.KupoAtlas (AtlasMatch (..), toGYAssetClass)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..), KupoValue (..))
import Palmares.TxBuilding.Utils (authenticateStateUTxO)
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
-- Inherited fix #3: a parseable datum at a script address proves nothing. 2 ADA plus a
-- hand-crafted inline datum poisoned the projections for free, so a state UTxO counts as
-- protocol state only when its value carries exactly one of the NFT its own datum names,
-- under our minting policy. These cases are the guard itself; wiring it into
-- 'projectChainEvent's branches lands with the Ingestion rewrite.
------------------------------------------------------------------------------------------------

ac :: Text -> GYAssetClass
ac t = either (error "bad fixture") id (toGYAssetClass t)

-- 56 hex chars = the 28-byte script hash GYMintingPolicyId's IsString instance requires; 58 would `error`.
ourPolicy :: GYMintingPolicyId
ourPolicy = "c0ffee00000000000000000000000000000000000000000000000001"

acX, acY, acForeign :: GYAssetClass
acX = ac "c0ffee00000000000000000000000000000000000000000000000001.5801" -- id X under our policy
acY = ac "c0ffee00000000000000000000000000000000000000000000000001.5902" -- id Y under our policy
acForeign = ac "deadbeef000000000000000000000000000000000000000000000002.5801" -- someone else's policy

authenticationTests :: TestTree
authenticationTests =
  testGroup
    "state-UTxO authentication (inherited fix #3)"
    [ testCase "a datum's own NFT, under our policy, authenticates" $
        authenticateStateUTxO ourPolicy acX (valueSingleton acX 1 <> valueFromLovelace 2_000_000) @?= True,
      testCase "no NFT in the value is not authentic (the free-dust forgery)" $
        authenticateStateUTxO ourPolicy acX (valueFromLovelace 2_000_000) @?= False,
      testCase "a datum naming id X in a UTxO holding NFT Y is not authentic" $
        authenticateStateUTxO ourPolicy acX (valueSingleton acY 1 <> valueFromLovelace 2_000_000) @?= False,
      testCase "the right token name under someone else's policy is not authentic" $
        authenticateStateUTxO ourPolicy acForeign (valueSingleton acForeign 1) @?= False,
      testCase "two copies of the NFT is not authentic" $
        authenticateStateUTxO ourPolicy acX (valueSingleton acX 2) @?= False,
      testCase "GYLovelace as the claimed id is never authentic" $
        authenticateStateUTxO ourPolicy GYLovelace (valueFromLovelace 2_000_000) @?= False
    ]

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
      valueConversionTests,
      authenticationTests
    ]
