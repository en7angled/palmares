{-# LANGUAGE OverloadedStrings #-}

-- | What the published CIP-57 blueprint says — asserted against the rendered document, not the
-- generator that produced it.
--
-- __The gap this closes.__ The blueprint is the artifact a third party hashes to decide whether the
-- script in front of them is the script this protocol published, which makes every byte of it a
-- security claim. It had a false one: @admin write-blueprint@ passes @blueprintProtocolParams@ — real
-- sibling validator hashes plus a placeholder oracle token, @AssetClass (CurrencySymbol "",
-- TokenName "")@ — and the minting policy was compiled against it and serialised into
-- @compiledCode@. CIP-57 derives the @hash@ field from @compiledCode@, so the document published a
-- 28-byte script hash belonging to no deployment. A verifier got a mismatch and no way to tell a
-- placeholder from a substituted script — the one question the blueprint exists to answer.
--
-- __Why these assertions and not a golden file.__ A checked-in expected document would catch this,
-- but it would also fail on every prose edit, and the prose in @Palmares.Onchain.Blueprint@ is a
-- published interface that gets edited. These assert the property instead: the parameterised
-- validator is described by its @parameters@ declaration and ships no code, the unparameterised ones
-- still ship code and hash, and the whole document is invariant under the 'ProtocolParams' it was
-- generated from. The last one is the general statement — it fails for any deployment-specific value
-- baked in anywhere, including ones nobody has thought of yet.
module UnitTests.Blueprint (tests) where

import Data.Aeson (Value (Array, Object, String), encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_, toList)
import Data.Text (Text)
import Data.Text qualified as Text
import Palmares.Onchain.Blueprint (contractBlueprint)
import Palmares.TxBuilding.Validators (mkProtocolParams)
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "CIP-57 blueprint"
    [ testCase "the parameterised minting policy is declared by parameter, not baked into a script" $ do
        entry <- requireValidator "Palmares Minting Policy"
        assertBool
          "the minting policy must declare its ProtocolParams under `parameters` — that declaration is \
          \the only honest description of a script whose hash is not fixed until deployment"
          (KeyMap.member "parameters" entry)
        assertBool
          "the minting policy must NOT publish `compiledCode`: the oracle token inside its \
          \ProtocolParams does not exist until the one-shot oracle NFT is minted, so any code here is \
          \the policy applied to a placeholder"
          (not (KeyMap.member "compiledCode" entry))
        assertBool
          "nor `hash`: CIP-57 derives it from `compiledCode`, so placeholder code publishes a script \
          \hash that no deployed policy has and that a verifier cannot tell from a substitution"
          (not (KeyMap.member "hash" entry)),
      -- The counterweight. Dropping a placeholder is only an improvement if what remains is still
      -- verifiable; stripping all five would "fix" the finding by making the document useless.
      testCase "the unparameterised validators still publish code and hash a reader can verify" $
        for_ unparameterisedValidators $ \title -> do
          entry <- requireValidator title
          let named claim = Text.unpack title <> " " <> claim
          assertBool
            (named "is unparameterised, so it must publish `compiledCode`")
            (KeyMap.member "compiledCode" entry)
          assertBool
            (named "is unparameterised, so its `hash` is every deployment's")
            (KeyMap.member "hash" entry),
      testCase "the document does not depend on the deployment it was generated from" $
        for_ (firstDivergence (renderedFor placeholderOracleToken) (renderedFor deployedOracleToken)) $ \atByte ->
          assertFailure
            ( "the rendered blueprint changed when the oracle token changed — something \
              \deployment-specific is baked into the published document, and whoever verifies \
              \against it verifies one deployment at best. "
                <> atByte
            )
    ]

-- | The document as @admin write-blueprint@ would render it for a given oracle token.
renderedFor :: AssetClass -> ByteString
renderedFor = encode . contractBlueprint . mkProtocolParams

-- | Where two rendered documents first differ, as a readable window, or 'Nothing' if identical.
-- Not @assertEqual@ on the two documents: each is around 100 KB of JSON, and a failure that dumps
-- 200 KB into a CI log is a failure nobody reads a second time.
firstDivergence :: ByteString -> ByteString -> Maybe String
firstDivergence a b
  | a == b = Nothing
  | otherwise =
      Just
        ( "First divergence at byte " <> show n <> " of " <> show (BL.length a) <> "/" <> show (BL.length b) <> ": "
            <> show (window a)
            <> " vs "
            <> show (window b)
        )
  where
    n = length (takeWhile id (BL.zipWith (==) a b))
    window = BL.take 100 . BL.drop (fromIntegral (max 0 (n - 20)))

-- | Titles of the validators that take no compile-time parameter. These are the entries whose
-- published hash is a fact about every deployment.
unparameterisedValidators :: [Text]
unparameterisedValidators =
  [ "Palmares Profiles Validator",
    "Palmares Attestations Validator",
    "Palmares Disputes Validator",
    "Palmares Oracle Validator"
  ]

-- | The @validators@ entry the rendered document gives for a title, or a test failure naming the
-- titles it does have — a renamed validator is otherwise indistinguishable from a missing field.
requireValidator :: Text -> IO (KeyMap.KeyMap Value)
requireValidator title =
  case filter ((== Just title) . titleOf) renderedValidators of
    [entry] -> pure entry
    [] ->
      assertFailure
        ("no validator titled " <> show title <> "; the document has " <> show (map titleOf renderedValidators))
    dupes -> assertFailure (show (length dupes) <> " validators titled " <> show title)
  where
    titleOf entry = case KeyMap.lookup "title" entry of
      Just (String t) -> Just t
      _ -> Nothing

-- | The @validators@ array of the document as @admin write-blueprint@ renders it.
renderedValidators :: [KeyMap.KeyMap Value]
renderedValidators =
  case toJSON (contractBlueprint (mkProtocolParams placeholderOracleToken)) of
    Object top | Just (Array vs) <- KeyMap.lookup "validators" top -> [entry | Object entry <- toList vs]
    _ -> []

-- | The value @admin write-blueprint@ actually passes, via @blueprintProtocolParams@.
placeholderOracleToken :: AssetClass
placeholderOracleToken = AssetClass (CurrencySymbol "", TokenName "")

-- | A stand-in for a real deployment's oracle NFT. The byte string is 28 bytes because a
-- 'CurrencySymbol' is, but nothing here depends on that: the point is only that it differs from the
-- placeholder, so a document that varies with its argument is caught whatever the difference is.
deployedOracleToken :: AssetClass
deployedOracleToken = AssetClass (CurrencySymbol "palmares-oracle-nft-currsym!", TokenName "oracle")
