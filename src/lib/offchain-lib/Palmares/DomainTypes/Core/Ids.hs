{-# LANGUAGE OverloadedStrings #-}

-- | Governance identifier codecs: CIP-129 (header-byte-prefixed) and CIP-105 (bare hash).
--
-- We compute every governance bech32 ourselves rather than reading one off @cardano-db-sync@:
--
--   * @drep_hash.view@ is the __CIP-105__ form (@serialiseToBech32 "drep"@ over the raw 28 bytes,
--     the same HRP for key and script credentials), so it cannot be compared against Koios,
--     GovTool or a wallet, all of which show CIP-129.
--   * @committee_hash@ has no @view@ column at all — only @id@, @raw@ and @has_script@ — so all
--     four @cc_hot@/@cc_cold@ forms are ours.
--   * @gov_action_proposal@ carries no bech32 id.
--
-- The header byte is @(key-type \<\< 4) .|. credential-type@:
--
-- > | identifier     | HRP          | key hash | script hash | payload               |
-- > | CC hot         | cc_hot       | 0x02     | 0x03        | 1 + 28 bytes          |
-- > | CC cold        | cc_cold      | 0x12     | 0x13        | 1 + 28 bytes          |
-- > | DRep (CIP-129) | drep         | 0x22     | 0x23        | 1 + 28 bytes          |
-- > | DRep (CIP-105) | drep         | (none)   | (none)      | 28 bytes              |
-- > | gov action     | gov_action   | (none)   | (none)      | 32-byte tx id + index |
module Palmares.DomainTypes.Core.Ids
  ( drepIdCip129,
    drepIdCip105,
    ccHotIdCip129,
    ccColdIdCip129,
    govActionIdCip129,
    parseGovActionIdCip129,
    poolIdBech32,
    anyVoterIdHex,
    parseDrepIdAny,
  )
where

import Codec.Binary.Bech32 qualified as Bech32
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char (isHexDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)

-- | Encode a payload under a literal HRP.
--
-- 'Bech32.encodeLenient', not 'Bech32.encode': the BIP-173 90-character limit is irrelevant at 29
-- or 33 bytes, and @encode@'s 'Either' would force a partial function onto a total operation. The
-- HRPs are module-level literals, so the 'error' below is unreachable by construction.
encodeWith :: Text -> ByteString -> Text
encodeWith h bs =
  Bech32.encodeLenient
    (either (error "Palmares.DomainTypes.Core.Ids: literal HRP rejected") id (Bech32.humanReadablePartFromText h))
    (Bech32.dataPartFromBytes bs)

-- | CIP-129 header byte for a key-type nibble and a credential kind.
header :: Word8 -> Bool -> Word8
header keyType isScript = (keyType `shiftL` 4) .|. (if isScript then 0x03 else 0x02)

-- | CIP-129 DRep id (@drep1…@) over a 28-byte credential hash. 'True' for a script credential.
drepIdCip129 :: Bool -> ByteString -> Text
drepIdCip129 isScript raw = encodeWith "drep" (BS.cons (header 0x2 isScript) raw)

-- | CIP-105 DRep id (@drep1…@): the bare 28-byte hash, no header byte. This is what db-sync's
-- @drep_hash.view@ contains, and it does not distinguish key from script credentials.
drepIdCip105 :: ByteString -> Text
drepIdCip105 = encodeWith "drep"

-- | CIP-129 constitutional-committee hot-credential id (@cc_hot1…@).
ccHotIdCip129 :: Bool -> ByteString -> Text
ccHotIdCip129 isScript raw = encodeWith "cc_hot" (BS.cons (header 0x0 isScript) raw)

-- | CIP-129 constitutional-committee cold-credential id (@cc_cold1…@).
ccColdIdCip129 :: Bool -> ByteString -> Text
ccColdIdCip129 isScript raw = encodeWith "cc_cold" (BS.cons (header 0x1 isScript) raw)

-- | CIP-129 governance action id (@gov_action1…@): the 32-byte proposal transaction id followed
-- by its 1-byte index within that transaction. No header byte.
govActionIdCip129 :: ByteString -> Word8 -> Text
govActionIdCip129 txId ix = encodeWith "gov_action" (txId <> BS.singleton ix)

-- | Parse any of the three DRep id forms a client may send, returning the script flag and the
-- raw 28-byte hash.
--
-- The flag is 'Maybe' on purpose: only CIP-129 carries it. CIP-105 and raw hex do not (HRP
-- @drep@ is used for both credential kinds), so 'Nothing' means \"resolve @has_script@ from
-- @drep_hash@ by @raw@\". Returning 'False' there would silently mis-identify every script DRep
-- at the identifier boundary the Koios reconciliation joins on.
--
-- The two reserved views @drep_always_abstain@ and @drep_always_no_confidence@ are not this
-- module's business — they are literals handled in the DTO layer — so they are rejected here.
parseDrepIdAny :: Text -> Either Text (Maybe Bool, ByteString)
parseDrepIdAny t = case Bech32.decode t of
  Right (hrp, dp)
    | Bech32.humanReadablePartToText hrp == "drep",
      Just bs <- Bech32.dataPartToBytes dp ->
        case BS.uncons bs of
          Just (h, rest)
            | BS.length bs == 29, h == 0x22 || h == 0x23 -> Right (Just (h == 0x23), rest)
          _ | BS.length bs == 28 -> Right (Nothing, bs)
          _ -> invalid
  _ | T.length t == 56, T.all isHexDigit t ->
        either (const invalid) (Right . (Nothing,)) (B16.decode (TE.encodeUtf8 t))
  _ -> invalid
  where
    invalid = Left "invalid_drep_id"

-- | Decode a CIP-129 governance action id back to its hex transaction id and index.
--
-- The inverse of 'govActionIdCip129'. The length check is the whole validation: the payload is a
-- 32-byte transaction id followed by a single index byte, with no header byte to disambiguate, so
-- a payload of any other length is not a governance action id whatever its HRP says.
--
-- The index is one byte because the ledger\'s @GovActionIx@ is a @Word16@ in the CDDL but CIP-129
-- fixes the encoding at one byte; a transaction with more than 256 proposals could not be
-- addressed either way, and none exists.
parseGovActionIdCip129 :: Text -> Either Text (Text, Word8)
parseGovActionIdCip129 t = case Bech32.decode t of
  Right (hrp, dp)
    | Bech32.humanReadablePartToText hrp == "gov_action",
      Just bs <- Bech32.dataPartToBytes dp,
      BS.length bs == 33,
      Just (txId, ix) <- BS.unsnoc bs ->
        Right (TE.decodeUtf8 (B16.encode txId), ix)
  _ -> Left "invalid_gov_action_id"

-- | CIP-5 stake pool id (@pool1…@) over the 28-byte pool hash.
--
-- No header byte and no CIP-129 form: a stake pool predates CIP-129 and every tool — cardano-cli,
-- every explorer, every pool listing — shows this one. Publishing anything else would make a pool
-- unsearchable.
poolIdBech32 :: ByteString -> Text
poolIdBech32 = encodeWith "pool"

-- | The 28-byte credential hash behind ANY voter identifier a client may send, as hex.
--
-- One function for all three roles, which is what lets @\/votes?voter_id=@ be a single parameter:
-- a DRep's @drep1y…@ or @drep1…@, a committee @cc_cold1…@ or @cc_hot1…@, a pool's @pool1…@, or 56
-- hex characters. The HRP decides how many leading bytes to drop, since only the CIP-129 forms
-- carry a header byte.
--
-- A @cc_hot1…@ is accepted and returns the HOT hash, which will not match a committee vote row —
-- those are keyed by the cold credential (D-24). That is the correct outcome rather than a
-- convenience: a hot key is not a stable identity, and silently resolving it to a cold one would
-- hide a hot-key rotation from a reader who asked about a specific hot key.
anyVoterIdHex :: Text -> Maybe Text
anyVoterIdHex t = case Bech32.decode t of
  Right (hrp, dp)
    | Just bs <- Bech32.dataPartToBytes dp,
      let h = Bech32.humanReadablePartToText hrp,
      Just raw <- strip h bs ->
        Just (TE.decodeUtf8 (B16.encode raw))
  _
    | T.length t == 56, T.all isHexDigit t -> Just (T.toLower t)
    | otherwise -> Nothing
  where
    -- CIP-129 payloads are 29 bytes with a leading header; CIP-105 and CIP-5 are the bare 28.
    strip h bs
      | BS.length bs == 29, h `elem` ["drep", "cc_cold", "cc_hot"] = Just (BS.drop 1 bs)
      | BS.length bs == 28, h `elem` ["drep", "pool"] = Just bs
      | otherwise = Nothing
