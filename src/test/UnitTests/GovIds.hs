{-# LANGUAGE OverloadedStrings #-}

-- | Golden vectors for the CIP-129/CIP-105 identifier codec. One real preprod id read from Koios on
-- 2026-10-19 (T-METRIC §4); the rest are the same 28 bytes re-encoded per T-DATA §1.3's header table.
module UnitTests.GovIds (govIdsTests) where

import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Palmares.DomainTypes.Core.Ids
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
        parseDrepIdAny "drep_always_abstain" @?= Left "invalid_drep_id"
    ]
