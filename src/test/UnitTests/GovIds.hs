{-# LANGUAGE OverloadedStrings #-}

-- | Golden vectors for the CIP-129/CIP-105 identifier codec. One real preprod id read from Koios on
-- 2026-10-19 (T-METRIC §4); the rest are the same 28 bytes re-encoded per T-DATA §1.3's header table.
module UnitTests.GovIds (govIdsTests) where

import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Ids
import Palmares.DomainTypes.Core.Types
  ( LevelOneAnchor (..),
    levelOneAnchorActionKey,
    levelOneAnchorAddressKey,
    parseLevelOneAnchor,
  )
import Data.String (fromString)
import Palmares.Onchain.CIP68 (validateOtherMetadata)
import Test.Tasty
import Test.Tasty.HUnit

-- | "Bitcows" preprod DRep, key credential (T-METRIC §4).
bitcowsRaw :: ByteString
bitcowsRaw = B16.decodeLenient "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"

bitcowsCip129 :: Text
bitcowsCip129 = "drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"

-- | The other six renderings of the SAME 28 bytes. Derived from T-DATA §1.3's header table with an
-- independent BIP-173 reference implementation, so they pin header byte, HRP and 5-bit regrouping.
bitcowsCip129Script, bitcowsCip105, bitcowsCcHot, bitcowsCcHotScript, bitcowsCcCold, bitcowsCcColdScript :: Text
bitcowsCip129Script = "drep1ywqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmuzqx0"
bitcowsCip105 = "drep1symc604gnd50plqfj393lyljl6u9zvv0r9he3wjq98v2sz3vtkp"
bitcowsCcHot = "cc_hot1q2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qf6qm49"
bitcowsCcHotScript = "cc_hot1qwqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qfgs24z"
bitcowsCcCold = "cc_cold1z2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qlx580v"
bitcowsCcColdScript = "cc_cold1zwqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32ql5yk0t"

-- | 32-byte tx id placeholder for the gov-action shape test.
txid32 :: ByteString
txid32 = BS.replicate 32 0xab

-- | Decode one of our own ids back to (hrp, payload bytes).
dec :: Text -> (Text, ByteString)
dec t = case Bech32.decode t of
  Right (hrp, dp) | Just bs <- Bech32.dataPartToBytes dp -> (Bech32.humanReadablePartToText hrp, bs)
  _ -> error ("undecodable: " <> T.unpack t)

govIdsTests :: TestTree
govIdsTests =
  testGroup
    "CIP-129 / CIP-105 identifiers"
    [ testCase "Bitcows DRep encodes to the Koios CIP-129 id" $
        drepIdCip129 False bitcowsRaw @?= bitcowsCip129,
      testCase "DRep key credential: hrp drep, 29 bytes, header 0x22" $
        let (hrp, bs) = dec (drepIdCip129 False bitcowsRaw)
         in (hrp, BS.length bs, BS.head bs, BS.tail bs) @?= ("drep", 29, 0x22, bitcowsRaw),
      testCase "DRep script credential: header 0x23" $
        (drepIdCip129 True bitcowsRaw, BS.head (snd (dec (drepIdCip129 True bitcowsRaw))))
          @?= (bitcowsCip129Script, 0x23),
      testCase "CIP-105 DRep: hrp drep, 28 bytes, no header" $
        (drepIdCip105 bitcowsRaw, dec (drepIdCip105 bitcowsRaw)) @?= (bitcowsCip105, ("drep", bitcowsRaw)),
      testCase "cc_hot key credential: header 0x02" $
        let (hrp, bs) = dec (ccHotIdCip129 False bitcowsRaw)
         in (hrp, BS.head bs, ccHotIdCip129 False bitcowsRaw) @?= ("cc_hot", 0x02, bitcowsCcHot),
      testCase "cc_hot script credential: header 0x03" $
        (ccHotIdCip129 True bitcowsRaw, BS.head (snd (dec (ccHotIdCip129 True bitcowsRaw))))
          @?= (bitcowsCcHotScript, 0x03),
      testCase "cc_cold key credential: header 0x12" $
        let (hrp, bs) = dec (ccColdIdCip129 False bitcowsRaw)
         in (hrp, BS.head bs, ccColdIdCip129 False bitcowsRaw) @?= ("cc_cold", 0x12, bitcowsCcCold),
      testCase "cc_cold script credential: header 0x13" $
        (ccColdIdCip129 True bitcowsRaw, BS.head (snd (dec (ccColdIdCip129 True bitcowsRaw))))
          @?= (bitcowsCcColdScript, 0x13),
      testCase "gov action: hrp gov_action, 33 bytes = txid || index, no header" $
        dec (govActionIdCip129 txid32 0) @?= ("gov_action", txid32 <> BS.singleton 0x00),
      testCase "parseDrepIdAny round-trips all three forms and rejects garbage" $ do
        parseDrepIdAny (drepIdCip129 True bitcowsRaw) @?= Right (Just True, bitcowsRaw)
        parseDrepIdAny (drepIdCip129 False bitcowsRaw) @?= Right (Just False, bitcowsRaw)
        parseDrepIdAny (drepIdCip105 bitcowsRaw) @?= Right (Nothing, bitcowsRaw)
        parseDrepIdAny "81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"
          @?= Right (Nothing, bitcowsRaw)
        parseDrepIdAny "drep_always_abstain" @?= Left "invalid_drep_id",
      stakeAddressTests,
      levelOneAnchorTests
    ]

-- | Encode a payload under a literal HRP. The test-side twin of @Palmares…Core.Ids.encodeWith@,
-- which is not exported — and should not be, since nothing outside that module should be minting
-- bech32 by hand except a test that is pinning the codec.
encodeBech32 :: Text -> ByteString -> Text
encodeBech32 h bs =
  Bech32.encodeLenient
    (either (error "UnitTests.GovIds: literal HRP rejected") id (Bech32.humanReadablePartFromText h))
    (Bech32.dataPartFromBytes bs)

-- | A 29-byte testnet reward address over the Bitcows credential: header @0xe0@ (stake key) plus the
-- 28-byte hash, which is the shape @stake_address.view@ holds on preprod.
stakeTestAddr :: Text
stakeTestAddr = encodeBech32 "stake_test" (BS.cons 0xe0 bitcowsRaw)

stakeAddressTests :: TestTree
stakeAddressTests =
  testGroup
    "stake addresses — ADR 0008's second anchor key"
    [ testCase "a testnet reward address decodes to itself" $
        parseStakeAddressBech32 stakeTestAddr @?= Right stakeTestAddr,
      -- The case folding is a fix, not a nicety. An all-uppercase address is legal BIP-173 and
      -- db-sync's `stake_address.view` is lowercase, so without the fold a valid address would
      -- resolve to no withdrawal — which a reader sees as "this payment never happened".
      testCase "an all-uppercase address is folded, not refused" $
        parseStakeAddressBech32 (T.toUpper stakeTestAddr) @?= Right stakeTestAddr,
      testCase "the mainnet HRP is accepted too, since one codec serves both networks" $
        let m = encodeBech32 "stake" (BS.cons 0xe1 bitcowsRaw)
         in parseStakeAddressBech32 m @?= Right m,
      testCase "28 bytes is not a reward address — the header byte is missing" $
        parseStakeAddressBech32 (encodeBech32 "stake_test" bitcowsRaw) @?= Left "invalid_stake_address",
      testCase "a DRep id over the SAME bytes is refused on its HRP" $
        parseStakeAddressBech32 (drepIdCip129 False bitcowsRaw) @?= Left "invalid_stake_address",
      testCase "a bad checksum is refused" $
        parseStakeAddressBech32 "stake_test1nope" @?= Left "invalid_stake_address"
    ]

-- | The level-1 anchor's shape, pinned where the two ids it is made of are pinned — __ADR 0008__.
--
-- The anchor is two reserved @otherMetadata@ keys rather than a datum field, because the datum
-- format is frozen by a live deployment and the specification itself decided the anchor is
-- unvalidated on chain. That makes these tests the ONLY place the shape is enforced before the
-- pointer becomes permanent, so the refusals matter more than the acceptances.
levelOneAnchorTests :: TestTree
levelOneAnchorTests =
  testGroup
    "the level-1 anchor in otherMetadata — ADR 0008"
    [ testCase "unrelated metadata is no anchor, and that is not an error" $
        parseLevelOneAnchor [("role", "auditor")] @?= Right Nothing,
      testCase "the action alone anchors to a governance action" $
        parseLevelOneAnchor [(levelOneAnchorActionKey, action0)]
          @?= Right (Just (LevelOneAnchor action0Canonical Nothing)),
      testCase "action plus address anchors to a treasury withdrawal" $
        parseLevelOneAnchor
          [(levelOneAnchorActionKey, action0), (levelOneAnchorAddressKey, stakeTestAddr)]
          @?= Right (Just (LevelOneAnchor action0Canonical (Just stakeTestAddr))),
      -- BOTH published forms, and this is the case the first version got wrong. The anchor parser
      -- accepted CIP-129 only, while `GET /treasury-withdrawals` — the very route that tells a client
      -- what there is to anchor to — publishes `<tx_hash>#<index>`. So copying an id out of the API
      -- and into an anchor was a 400. Measured against the live route, not reasoned about.
      testCase "either published form of the same id canonicalises identically" $
        ( parseLevelOneAnchor [(levelOneAnchorActionKey, action0)],
          parseLevelOneAnchor [(levelOneAnchorActionKey, action0Canonical)]
        )
          @?= ( Right (Just (LevelOneAnchor action0Canonical Nothing)),
                Right (Just (LevelOneAnchor action0Canonical Nothing))
              ),
      -- An address alone has nothing to resolve against: `palmares.treasury_withdrawal` is keyed by
      -- the PAIR, and one address can be paid under many actions.
      testCase "an address with no action is refused, not silently ignored" $
        isLeft (parseLevelOneAnchor [(levelOneAnchorAddressKey, stakeTestAddr)]) @?= True,
      -- The two cases a `Maybe` return would have hidden: publishing a malformed anchor as "no
      -- anchor" would make the API say unanchored about a datum that permanently says otherwise.
      testCase "a malformed action is a refusal, never an absent anchor" $
        isLeft (parseLevelOneAnchor [(levelOneAnchorActionKey, "gov_action1nope")]) @?= True,
      testCase "a malformed address is a refusal, with the action valid" $
        isLeft
          ( parseLevelOneAnchor
              [(levelOneAnchorActionKey, action0), (levelOneAnchorAddressKey, "stake_test1nope")]
          )
          @?= True,
      -- The action canonicalises to the HASH form — what every response carries and what
      -- `/gov-action/{id}` takes back — and the address to lowercase, so both can be fed straight
      -- back into the API with no second normalisation nobody would remember.
      testCase "both ids come back canonical, so they can be fed straight back into the API" $
        parseLevelOneAnchor
          [ (levelOneAnchorActionKey, T.toUpper action0),
            (levelOneAnchorAddressKey, T.toUpper stakeTestAddr)
          ]
          @?= Right (Just (LevelOneAnchor action0Canonical (Just stakeTestAddr))),
      -- Through the REAL on-chain gate, not against copied constants. The minting policy validates
      -- these two entries like any other `otherMetadata` pair — count, key length, value length,
      -- duplicates, collisions with name/description/image — so the day someone tightens
      -- `validateOtherMetadata` the anchor must not become unmintable in silence. This is the only
      -- test that ties ADR 0008's choice of carrier to the carrier's own rules.
      -- It also pins that neither key IS one of the three CIP-68 reserved keys: `name` as an anchor
      -- key would make this False.
      testCase "the minting policy accepts the anchor as ordinary metadata" $
        validateOtherMetadata (map (\(k, v) -> (bbs k, bbs v)) anchorEntries) @?= True
    ]
  where
    action0 = govActionIdCip129 txid32 0
    -- The form every response carries: 64 hex characters of transaction id, then the index.
    action0Canonical = T.replicate 32 "ab" <> "#0"
    anchorEntries =
      [(levelOneAnchorActionKey, action0), (levelOneAnchorAddressKey, stakeTestAddr)]
    bbs = fromString . T.unpack
