{-# LANGUAGE OverloadedStrings #-}

-- | What a mint handler accepts from a redeemer and writes into a permanent datum.
--
-- Three of this protocol's five audit findings in the mint path had the same shape: a redeemer field
-- went into a datum that nothing can ever change, and the handler checked less about it than the
-- datum's later readers assume. Nothing in this protocol burns, so "permanent" is literal.
--
-- Both predicates here are pure functions of their argument, so the rules are pinned without
-- building a transaction; @UnitTests.Attestation@ and @UnitTests.Dispute@ carry the emulator cases
-- that drive real transactions into @Mg@, @Mn@ and @Md4@.
--
-- The first case in each group is the one that fails on the old code, per @src/test/CLAUDE.md@.
module UnitTests.MintInputs (tests) where

import Palmares.Onchain.CIP68
  ( deriveUserFromRefTN,
    generateRefAndUserTN,
    isProtocolRefToken,
    isRefTokenName,
    maxOtherMetadataEntries,
    validateOtherMetadata,
  )
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import PlutusTx.Builtins (BuiltinByteString)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "mint-path redeemer inputs"
    [ refTokenTests,
      otherMetadataTests
    ]

-- | @Mg@ and @Md4@: a protocol id must be a REFERENCE token, not merely this protocol's symbol.
refTokenTests :: TestTree
refTokenTests =
  testGroup
    "a protocol id is a reference token"
    [ -- THE CASE THE OLD CHECK ACCEPTED. `hasCurrencySymbol` alone let a profile's USER token stand
      -- in as that profile's id.
      testCase "a USER token name is NOT a reference token name" $
        isRefTokenName userTN @?= False,
      testCase "a REF token name is" $
        isRefTokenName refTN @?= True,
      -- AND HERE IS WHY IT MATTERED, stated as a fact about the derivation rather than about the
      -- guard: `deriveUserFromRefTN` replaces the first four bytes with the user prefix, so on a
      -- name that already starts with the user prefix it is the IDENTITY. `Mf` and `A1` both ask the
      -- transaction to spend `deriveUserFromRefAC <id>`, so naming a profile's user token as its own
      -- id makes those checks ask for the very token the profile's real owner holds — the attestation
      -- is issued and accepted by exactly the right people, and recorded under an id no profile
      -- projection has. Accepted on chain, detached in the read layer.
      testCase "deriving the user token from a USER token name is the identity, which is the hole" $
        deriveUserFromRefTN userTN @?= userTN,
      testCase "deriving the user token from a REF token name actually derives" $
        (deriveUserFromRefTN refTN == refTN, deriveUserFromRefTN refTN) @?= (False, userTN),
      -- Names too short to carry a prefix. `sliceByteString 0 4` on a shorter string returns what is
      -- there rather than failing, so these would pass a naive length-blind comparison.
      testCase "an empty token name is not a reference token name" $
        isRefTokenName (TokenName "") @?= False,
      testCase "a token name shorter than the prefix is not a reference token name" $
        isRefTokenName (TokenName "\0\6\67") @?= False,
      -- A name whose first four bytes are something else entirely.
      testCase "an unprefixed token name is not a reference token name" $
        isRefTokenName (TokenName "plainname") @?= False,
      -- And the combined predicate: BOTH halves are required, so each one failing alone is a refusal.
      testCase "the right prefix under the WRONG policy is refused" $
        isProtocolRefToken (AssetClass (otherCS, refTN)) ourCS @?= False,
      testCase "the right policy with the WRONG prefix is refused" $
        isProtocolRefToken (AssetClass (ourCS, userTN)) ourCS @?= False,
      testCase "the right policy and the right prefix is accepted" $
        isProtocolRefToken (AssetClass (ourCS, refTN)) ourCS @?= True
    ]
  where
    -- Built with the protocol's own generator rather than hand-written prefixes, so this test cannot
    -- disagree with the implementation about what CIP-67's four bytes are.
    (refTN, userTN) = generateRefAndUserTN "seedhash"
    ourCS = CurrencySymbol "c0ffee"
    otherCS = CurrencySymbol "decafe"

-- | @Mn@: the caller-supplied half of the metadata map, which used to be carried through unchecked.
otherMetadataTests :: TestTree
otherMetadataTests =
  testGroup
    "otherMetadata is bounded and its keys are unique"
    [ -- THE TWO CASES THE OLD CODE ACCEPTED, and they are different kinds of wrong.
      --
      -- Unbounded size is griefing the SUBJECT, not the issuer: `A1` re-locks `ownValue`, so the
      -- subject is who has to spend and relock the UTxO to accept, and nothing burns it.
      testCase "more than the entry limit is refused" $
        validateOtherMetadata (entries (limit + 1)) @?= False,
      -- Duplicate keys break `AssocMap.unsafeFromList`'s precondition, after which `lookup` returns
      -- whichever entry comes first while an off-chain decoder is free to disagree. The datum means
      -- two different things depending on who reads it.
      testCase "a duplicate key is refused" $
        validateOtherMetadata [("role", "auditor"), ("role", "vendor")] @?= False,
      -- The worst version of a duplicate: shadowing one of the three keys `mkCIP68Datum` writes
      -- itself, which would let otherMetadata rewrite the display name.
      testCase "a key colliding with a reserved key is refused" $
        map (validateOtherMetadata . reserved) ["name", "description", "image"] @?= [False, False, False],
      testCase "exactly the entry limit is accepted" $
        validateOtherMetadata (entries limit) @?= True,
      testCase "no entries at all is accepted" $
        validateOtherMetadata [] @?= True,
      -- Field sizes, at the boundary and one past it, because an off-by-one here is the difference
      -- between a bounded datum and an unbounded one.
      testCase "a key at the limit is accepted and one past it is refused" $
        ( validateOtherMetadata [(bytes 64, "v")],
          validateOtherMetadata [(bytes 65, "v")]
        )
          @?= (True, False),
      testCase "a value at the limit is accepted and one past it is refused" $
        ( validateOtherMetadata [("k", bytes 256)],
          validateOtherMetadata [("k", bytes 257)]
        )
          @?= (True, False),
      -- An ordinary map, which is what this has to keep working for.
      testCase "distinct keys within the limits are accepted" $
        validateOtherMetadata [("role", "auditor"), ("engagement", "2026-Q4"), ("scope", "treasury")]
          @?= True
    ]
  where
    limit = maxOtherMetadataEntries

    -- Distinct keys, so the only thing n+1 entries can fail on is the count.
    entries n = [(bytes 1 <> intKey i, "v") | i <- [1 .. n]]
    intKey i = bytes i

    reserved k = [(k, "shadowed")]

    bytes :: Integer -> BuiltinByteString
    bytes n = foldr (\_ acc -> "a" <> acc) "" [1 .. n]
