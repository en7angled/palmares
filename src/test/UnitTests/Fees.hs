{-# LANGUAGE OverloadedStrings #-}

-- | Which fee a minting action costs — inherited fix #1.
--
-- __The bug this replaces.__ The inherited signature was
-- @checkFee :: OracleParams -> (FeeConfig -> Integer) -> [TxOut] -> Bool@: the fee was selected by
-- passing a field accessor, so every call site was a place the wrong field could be named. One of them
-- was — the Belt System's interval fee charged the membership-history field. The shape is the defect,
-- not the typo.
--
-- Now there is 'feeFor', the only function on chain or off that names a 'FeeConfig' field, and
-- 'checkFee' takes a 'MintAction'. The old shape is no longer expressible, which is why the type is
-- most of the fix; what remains testable is that the mapping is a bijection onto distinct fields, and
-- that is what a mis-wired arm would break.
--
-- The "one naming site" half of the invariant is asserted by @scripts/check_vocabulary.sh@, because it
-- is a property of the whole source tree rather than of any value.
module UnitTests.Fees (tests) where

import Palmares.Onchain.Protocol.Lookup (feeFor)
import Palmares.Onchain.Protocol.Types (FeeConfig (..), MintAction (..))
import PlutusLedgerApi.V3 (Address (..), Credential (PubKeyCredential), PubKeyHash (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "fees name one field in one place"
    [ -- Distinct values per field, so a swapped arm shows up as a wrong number rather than as a
      -- coincidence. This is the test that fails on the old behaviour: with the selector-passing
      -- shape, nothing stopped a caller handing `fcAttestationFee` to the profile path, and the
      -- result was indistinguishable from correct until someone compared invoices.
      testCase "each action maps to its own FeeConfig field" $
        map (`feeFor` distinctFees) [MintActionProfile, MintActionAttestation] @?= [11, 22],
      -- Over the actions that NAME a field. MintActionDispute is deliberately not one of them — it
      -- maps to a constant zero, because a refundable deposit already bounds disputes and a
      -- non-refundable fee on top would tax contesting a false claim. Including it here would make
      -- this a test about constants rather than about fields.
      testCase "no two actions share a field" $
        let fees = map (`feeFor` distinctFees) pricedActions
         in length (dedupe fees) @?= length pricedActions,
      -- Zero is the configured value on preprod — spec §4.3 rules out protocol fees as a business
      -- model — so the zero case has to be the ordinary one, not an edge case.
      testCase "every action is free when every fee is zero, which is the preprod configuration" $
        map (`feeFor` zeroFees) allActions @?= replicate (length allActions) 0
    ]
  where
    -- Driven off the constructor list, not a hand-written one. The hand-written one named two
    -- actions and called itself every action, so MintActionDispute arrived untested here.
    allActions = [minBound .. maxBound] :: [MintAction]

    pricedActions = [MintActionProfile, MintActionAttestation]

    distinctFees =
      FeeConfig
        { fcFeeAddress = Address (PubKeyCredential (PubKeyHash "\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1\1")) Nothing,
          fcProfileCreationFee = 11,
          fcAttestationFee = 22
        }

    zeroFees = distinctFees {fcProfileCreationFee = 0, fcAttestationFee = 0}

    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
