{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Palmares.DomainTypes.Core.Types where

import Data.Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Char (isHexDigit)
import Data.List.Extra
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Swagger (NamedSchema (..), ToSchema (..), genericDeclareNamedSchema)
import Data.Swagger.Internal.Schema ()
import Data.Swagger.ParamSchema
import Data.Swagger.SchemaOptions (fromAesonOptions)
import Data.Text hiding (init, tail)
import Data.Text as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TRead
import Data.Time (UTCTime)
import Database.Persist.TH
import Deriving.Aeson
import GHC.Generics ()
import GeniusYield.Types (GYAssetClass)
import GeniusYield.Types.Time
import Servant (FromHttpApiData (..))
import Palmares.DomainTypes.Core.Ids
  ( ccColdIdCip129,
    drepIdCip129,
    govActionIdCip129,
    parseDrepIdAny,
    parseGovActionIdCip129,
    parseStakeAddressBech32,
    poolIdBech32,
  )
import Palmares.Utils

type ProfileRefAC = GYAssetClass

type AttestationAC = GYAssetClass

-- | What kind of actor a profile stands for — the off-chain mirror of
-- 'Palmares.Onchain.Protocol.Types.OnchainProfileKind', same six constructors in the same order.
--
-- The wire form is snake_case, like every other enum in this API (@person_drep@, @organization@, …),
-- which the @ConstructorTagModifier@ below derives rather than a hand-written table.
data ProfileType
  = PersonDRep
  | Organization
  | Committee
  | Community
  | Vendor
  | Auditor
  deriving (Show, Generic, Eq, Ord, Enum, Bounded)
  deriving
    (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] ProfileType

-- | Read out of 'ToJSON', not derived — see 'AttestationType' for the measurement.
--
-- __This was derived, and it was the same latent defect__: a derived instance publishes
-- @PersonDRep@ while 'parseProfileType' and 'FromJSON' accept @person_drep@. It has not bitten yet
-- only because no documented route mentions a profile type — @ProfileType@ is absent from both
-- generated Swagger documents today. It would have become a live wire-contract lie the moment the
-- profile routes land, so it is corrected here, where the identical fix for 'AttestationType' is.
instance ToSchema ProfileType where
  declareNamedSchema _ = pure (NamedSchema (Just "ProfileType") (jsonEnumSchema (Proxy :: Proxy ProfileType)))

instance ToParamSchema ProfileType where
  toParamSchema = jsonEnumParamSchema

derivePersistFieldJSON "ProfileType"

-- | Parse a 'ProfileType' from its wire spelling.
--
-- Driven by the derived 'ToJSON' form rather than a second table, so a new constructor cannot be
-- parseable in one direction only. Exported because the admin CLI needs it too, and a second copy of
-- the lookup is how the two spellings would drift.
parseProfileType :: Text -> Maybe ProfileType
parseProfileType s = lookup s [(profileTypeText k, k) | k <- [minBound .. maxBound]]

instance FromHttpApiData ProfileType where
  parseQueryParam :: Text -> Either Text ProfileType
  parseQueryParam t = maybe (Left ("Invalid profile type: " <> t)) Right (parseProfileType t)

-- | The wire spelling of a 'ProfileType', from its own 'ToJSON'.
profileTypeText :: ProfileType -> Text
profileTypeText k = case toJSON k of
  String s -> s
  _ -> T.pack (show k)

-- | Profile
data Profile = Profile
  { profileId :: ProfileRefAC,
    profileName :: Text,
    profileDescription :: Text,
    profileImageURI :: Text,
    profileType :: ProfileType
  }
  deriving (Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "profile", CamelToSnake]] Profile

derivePersistFieldJSON "Profile"

instance Show Profile where
  show :: Profile -> String
  show (Profile {..}) =
    Prelude.unlines
      [ "┌─────────────────────────────────────────────────────────────",
        "│ Name: " <> stringFromJSON profileName,
        "│ Description: " <> stringFromJSON profileDescription,
        "│ Image URI: " <> stringFromJSON profileImageURI,
        "│ ID: " <> stringFromJSON profileId,
        "└─────────────────────────────────────────────────────────────"
      ]

instance ToSchema Profile where
  declareNamedSchema = genericDeclareNamedSchema profileSchemaOptions
    where
      profileSchemaOptions :: SchemaOptions
      profileSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "profile"
            }

-- | JSON-serialized @[(Text, Text)]@ for attestation projections (array of @[key, value]@ string pairs).
newtype AttestationOtherMetadataJson = AttestationOtherMetadataJson
  { fromAttestationOtherMetadataJson :: [(Text, Text)]
  }
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | What an attestation asserts about its subject — the off-chain mirror of
-- 'Palmares.Onchain.Protocol.Types.AttestationKind', same five constructors in the same order.
--
-- Named @AttestationType@ off-chain and @AttestationKind@ on-chain, which is the existing
-- 'ProfileType' \/ @OnchainProfileKind@ split rather than a new one. The name is also not free:
-- 'Palmares.WebAPI.Utils.addSharedSwaggerDescriptions' has carried a description for a definition
-- named @AttestationType@ since before the type existed, and the lens was a silent no-op until now.
data AttestationType
  = MilestoneDelivered
  | AuditPassed
  | Affiliation
  | RoleHeld
  | Endorsement
  | -- | A profile binding itself to a Cardano credential — __ADR 0003__.
    --
    -- Self-issued: the subject and the issuer are the same profile, because the two parties to a
    -- binding are the profile and the CREDENTIAL, and a credential is not a profile. The profile's
    -- consent is its user token; the credential's is a proof of control in the same transaction.
    --
    -- This is where a profile's credential lives now. It was a field on the profile, set once and
    -- cleared by a destructive redeemer — which an audit found irreversible and reachable with a
    -- weak proof, so it became a record in the append-only log instead.
    CredentialClaim
  | -- | A credential withdrawing from a claim — __ADR 0003__. A later fact, never an erasure: the
    -- claim stays in the log and the read layer stops publishing the binding.
    CredentialWithdrawal
  deriving (Show, Generic, Eq, Ord, Enum, Bounded)
  deriving
    (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] AttestationType

-- | Read out of 'ToJSON' with 'jsonEnumSchema', NOT derived.
--
-- __A derived 'ToSchema' publishes the CONSTRUCTOR names__ — @MilestoneDelivered@ — while
-- 'ToJSON' publishes @milestone_delivered@. That document describes five values the API rejects, and
-- it compiles, and nothing downstream notices: it was measured in the generated
-- @interaction-swagger-api.json@ before this instance existed. Every other enum in this module
-- already does it this way; the derived instance is the trap.
instance ToSchema AttestationType where
  declareNamedSchema _ = pure (NamedSchema (Just "AttestationType") (jsonEnumSchema (Proxy :: Proxy AttestationType)))

-- | @kind@ on @GET \/attestations@ and @GET \/profiles@, as a repeatable query parameter.
--
-- Both read out of the type's own 'Data.Aeson.ToJSON' rather than from a second table, for the
-- reason every other enum in this module does: the wire strings live in ONE place, so the documented
-- @enum@ and the accepted values are the same list, and a sixth attestation kind becomes parseable
-- and documented the moment it is constructible. 'ProfileType' above carries the identical pair.
instance ToParamSchema AttestationType where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData AttestationType where
  parseQueryParam = parseJsonEnumParam "invalid_parameter"

derivePersistFieldJSON "AttestationType"

-- | Parse an 'AttestationType' from its wire spelling.
--
-- Driven by the derived 'ToJSON' rather than a second table, so a new constructor cannot be
-- parseable in one direction only — the same reason 'parseProfileType' is written this way.
parseAttestationType :: Text -> Maybe AttestationType
parseAttestationType s = lookup s [(attestationTypeText k, k) | k <- [minBound .. maxBound]]

-- | The wire spelling of an 'AttestationType', from its own 'ToJSON'.
attestationTypeText :: AttestationType -> Text
attestationTypeText k = case toJSON k of
  String s -> s
  _ -> T.pack (show k)

-- | An attestation one profile issued about another.
data Attestation = Attestation
  { attestationId :: AttestationAC,
    attestationSubjectProfileId :: ProfileRefAC,
    attestationIssuerProfileId :: ProfileRefAC,
    attestationKind :: AttestationType,
    -- | The credential this record binds, as CIP-129 text, for the two credential kinds — and
    -- 'Nothing' for every other kind. __ADR 0003.__
    --
    -- On chain @Mc2@ requires it present on a claim or a withdrawal and @Mc4@ requires it absent
    -- elsewhere, so this field being 'Just' on an @endorsement@ would be a projection bug, not a
    -- record the chain allows.
    --
    -- __It is the source of @profile_credential@, not a copy of it.__ A profile's published
    -- credential is derived by replaying these: the latest 'CredentialClaim' for that subject with
    -- no later 'CredentialWithdrawal' naming the same credential.
    attestationCredential :: Maybe Text,
    attestationAttestationDate :: GYTime,
    -- | The period the attestation CLAIMS, self-reported and never chain-verified.
    --
    -- Published as @claimed_period@ precisely so that it cannot be mistaken for
    -- @attestation_date@, which is the issuance time and IS bounded by the transaction's validity
    -- interval. A consumer that renders the two alike is claiming something the chain never said.
    -- Both bounds or neither: a half-open period is not representable, by design.
    attestationClaimedPeriod :: Maybe (GYTime, GYTime),
    attestationAccepted :: Bool,
    attestationName :: Text,
    attestationDescription :: Text,
    attestationImageURI :: Text,
    attestationOtherMetadata :: [(Text, Text)],
    -- | On-chain pointer to the mint transaction (projected backend only; 'Nothing' on the live backend).
    attestationTxHash :: Maybe Text,
    attestationSlot :: Maybe Integer,
    attestationOutputIndex :: Maybe Int
  }
  deriving (Generic)
  deriving (ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "attestation", CamelToSnake]] Attestation

instance FromJSON Attestation where
  parseJSON = withObject "Attestation" $ \o ->
    Attestation
      <$> o .: "id"
      <*> o .: "subject_profile_id"
      <*> o .: "issuer_profile_id"
      <*> o .: "kind"
      -- Positional, like every line here, so this one had to be inserted where the field is — the
      -- hazard the record's own neighbours are commented about, met in the one hand-written parser.
      <*> o .:? "credential"
      <*> o .: "attestation_date"
      <*> o .:? "claimed_period"
      <*> o .: "accepted"
      <*> o .: "name"
      <*> o .: "description"
      <*> o .: "image_uri"
      <*> o .:? "other_metadata" .!= []
      <*> o .:? "tx_hash"
      <*> o .:? "slot"
      <*> o .:? "output_index"

derivePersistFieldJSON "Attestation"
derivePersistFieldJSON "AttestationOtherMetadataJson"

instance Show Attestation where
  show :: Attestation -> String
  show (Attestation {..}) =
    Data.List.Extra.intercalate
      "\n"
      [ "┌─────────────────────────────────────────────────────────────",
        "│ Attestation ID: " <> stringFromJSON attestationId,
        "│ Name: " <> stringFromJSON attestationName,
        "│ Issued To: " <> stringFromJSON attestationSubjectProfileId,
        "│ Issued By: " <> stringFromJSON attestationIssuerProfileId,
        "│ Kind: " <> stringFromJSON attestationKind,
        "│ Issued On: " <> stringFromJSON attestationAttestationDate,
        -- Labelled "claimed", not "period", because this printout is what an operator reads when
        -- they are deciding whether a record says what they think it says.
        "│ Claimed period: "
          <> maybe "—" (\(f, t) -> stringFromJSON f <> " … " <> stringFromJSON t) attestationClaimedPeriod,
        "│ Accepted: " <> show attestationAccepted,
        "│ Other metadata pairs: " <> show (Prelude.length attestationOtherMetadata),
        "└─────────────────────────────────────────────────────────────"
      ]

instance ToSchema Attestation where
  declareNamedSchema = genericDeclareNamedSchema attestationSchemaOptions
    where
      attestationSchemaOptions :: SchemaOptions
      attestationSchemaOptions =
        fromAesonOptions $
          AesonTypes.defaultOptions
            { AesonTypes.fieldLabelModifier = camelTo2 '_' . dropPrefix "attestation"
            }

-- | The @otherMetadata@ key carrying the governance action an attestation is anchored to —
-- __ADR 0008__.
levelOneAnchorActionKey :: Text
levelOneAnchorActionKey = "palmares:level1_gov_action"

-- | The @otherMetadata@ key carrying the stake address paid by the anchored withdrawal.
levelOneAnchorAddressKey :: Text
levelOneAnchorAddressKey = "palmares:level1_stake_address"

-- | An attestation's optional pointer at the level-1 fact it comments on — __ADR 0008__.
--
-- The action alone anchors to a governance action; the action plus an address anchors to the
-- treasury withdrawal that pair names, which is how @palmares.treasury_withdrawal@ is keyed. This is
-- what links money to delivery: the chain says "address X received N ADA under action G" and the
-- attestation says "the paying committee confirms milestone 2".
--
-- __Nothing on chain checks that the fact exists__, by the specification's own decision (§4.3): a
-- treasury withdrawal is not an addressable UTxO, so there is no reference input to verify against.
-- The pointer is confronted with the data at READ time and the API says whether it resolved. A
-- consumer that renders an unresolved anchor as a payment is claiming something nobody said.
data LevelOneAnchor = LevelOneAnchor
  { anchorGovActionId :: Text,
    anchorStakeAddress :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving
    (FromJSON, ToJSON)
    via CustomJSON '[FieldLabelModifier '[StripPrefix "anchor", CamelToSnake]] LevelOneAnchor

instance ToSchema LevelOneAnchor where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "anchor")

-- | Read an attestation's level-1 anchor out of its @otherMetadata@ entries — __ADR 0008__.
--
-- Three outcomes, and the middle one is the reason this is not a @Maybe@:
--
--   * @Right Nothing@ — no anchor. Most attestations: a vendor paid from an organization's budget
--     has no on-chain payment fact and belongs in the registry anyway (spec §2).
--   * @Right (Just a)@ — an anchor whose SHAPE is valid. Not a claim that the fact exists.
--   * @Left msg@ — the keys are present and malformed. Returning @Nothing@ here would publish an
--     attestation as unanchored while its datum permanently says otherwise, which is the one answer
--     that is a lie.
--
-- The message is prose, not an error code, because the two callers have different vocabularies — the
-- write API answers in @TxBuildingException@ codes and the read API in 'ErrorCode' — and a shared
-- domain function that picked one would force the other to re-map a string it did not choose.
--
-- Both fields come back CANONICAL — the action as @\<tx_hash\>#\<index\>@, which is the form every
-- response carries, and the address lowercased (see 'parseStakeAddressBech32') — so they can be fed
-- straight back into @\/gov-action\/{id}@ and compared against
-- @palmares.treasury_withdrawal.stake_address@ without a second normalisation nobody would remember.
parseLevelOneAnchor :: [(Text, Text)] -> Either Text (Maybe LevelOneAnchor)
parseLevelOneAnchor entries =
  case (lookup levelOneAnchorActionKey entries, lookup levelOneAnchorAddressKey entries) of
    (Nothing, Nothing) -> Right Nothing
    -- An address with no action is not half an anchor: `palmares.treasury_withdrawal` is keyed by
    -- the PAIR, and one address can be paid by many actions, so there is nothing to resolve.
    (Nothing, Just _) ->
      Left $
        "a level-1 anchor needs its governance action: " <> levelOneAnchorActionKey <> " is missing"
    -- BOTH published forms, through the API's own parser rather than a second one. Measured, and it
    -- is the whole reason this does not call 'parseGovActionIdCip129' directly:
    -- @GET /treasury-withdrawals@ publishes @gov_action_id@ as @\<tx_hash\>#\<index\>@, so a client
    -- copying an id out of the very route that tells it what to anchor to would have been refused
    -- with a 400. 'FromHttpApiData' 'GovActionId' accepts the bech32 AND the hash form and
    -- canonicalises to the hash form, which is what every response carries and what
    -- @\/gov-action\/{id}@ takes back.
    (Just action, addr) -> case parseUrlPiece action :: Either Text GovActionId of
      Left _ ->
        Left $
          levelOneAnchorActionKey
            <> " is not a governance action id (gov_action1… or <tx_hash>#<index>)"
      Right (GovActionId canonical) -> case traverse parseStakeAddressBech32 addr of
        Left _ -> Left $ levelOneAnchorAddressKey <> " is not a bech32 stake address (stake…/stake_test…)"
        Right addr' -> Right (Just (LevelOneAnchor canonical addr'))

-- | The two anchor keys, for a caller that has to filter them out of a raw metadata listing.
levelOneAnchorKeys :: [Text]
levelOneAnchorKeys = [levelOneAnchorActionKey, levelOneAnchorAddressKey]

-- | What became of an attestation's level-1 anchor when the read layer confronted it with the data
-- — __ADR 0008__.
--
-- Three values, and a UI must distinguish them because they mean three different things to a reader:
--
--   * @resolved@ — the action, and the withdrawal if an address was given, exist in the index. Show
--     the link, and the amount when a withdrawal came back.
--   * @unresolved@ — the pointer parses and names nothing the index holds. Show the pointer with a
--     plain "not found" marker. __Never hide it__: the datum permanently says this attestation is
--     about that payment, and an attestation rendered as unanchored is a different claim.
--   * @malformed@ — the keys are there and do not parse. Show them as unreadable. Only a hand-built
--     transaction can produce this, because the write API refuses it.
--
-- Deliberately NOT a boolean. "Did it resolve" collapses the second and third cases, and they have
-- different causes: one is a pointer at something that is not there, the other is not a pointer.
data LevelOneAnchorStatus
  = L1Resolved
  | L1Unresolved
  | L1Malformed
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[ConstructorTagModifier '[StripPrefix "L1", CamelToSnake]] LevelOneAnchorStatus

instance ToSchema LevelOneAnchorStatus where
  declareNamedSchema _ =
    pure (NamedSchema (Just "LevelOneAnchorStatus") (jsonEnumSchema (Proxy :: Proxy LevelOneAnchorStatus)))

-- | How a dispute ended — the off-chain mirror of
-- 'Palmares.Onchain.Protocol.Types.Verdict', the same three constructors in the same order.
--
-- Two FINDINGS and no third, because __the deposit comes back either way__: there is no punitive
-- verdict for the admin to levy, so losing a dispute costs network fees and nothing else. An upheld
-- dispute is published beside the attestation it contests and the attestation is never hidden or
-- deleted (spec §4.3).
--
-- @expired@ is the third constructor and NOT a third finding: nobody decided it. After the
-- dispute's own deadline anyone may close an undecided dispute, which is the exit D-A added for the
-- case where the admin simply does not act — see
-- 'Palmares.Onchain.Protocol.Types.VerdictExpired'. __The read layer must not render it as a
-- finding against either side__, and in particular must not show an expired dispute the way it
-- shows an upheld one.
data DisputeVerdict = VerdictUpheld | VerdictRejected | VerdictExpired
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "Verdict", CamelToSnake]] DisputeVerdict

instance ToSchema DisputeVerdict where
  declareNamedSchema _ = pure (NamedSchema (Just "DisputeVerdict") (jsonEnumSchema (Proxy :: Proxy DisputeVerdict)))

-- ---------------------------------------------------------------------------------------------

-- * Governance ids and enums

--
-- The wire vocabulary of the public API. Two rules hold throughout:
--
--   1. Every enum's wire strings are written ONCE, in its @ToJSON@ instance. The Swagger @enum@
--      and the query-parameter parser are both read back out of it with 'jsonEnumSchema' and
--      'parseJsonEnumParam', so a documented value cannot drift from an accepted one.
--   2. The values mirror what the @palmares@ views emit. Where a view computes a verdict — the
--      anchor status, the governance-action state, the committee status — Haskell CONSUMES it and
--      never recomputes it (D-10). A second classifier is a second answer.

-- | A DRep, in the CIP-129 rendering (@drep1y…@ for a key credential, @drep1yw…@ for a script
-- one), or one of the two reserved ledger options verbatim.
--
-- Responses always carry this form, built from the database's @(drep_raw, has_script)@ pair.
-- 'drep_hash.view' is deliberately never published: it is the CIP-105 rendering, which uses one
-- HRP for both credential kinds and therefore cannot be compared against Koios, GovTool or a
-- wallet.
newtype DRepId = DRepId {unDRepId :: Text}
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON)

instance ToSchema DRepId where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy Text)

instance ToParamSchema DRepId where
  toParamSchema _ = toParamSchema (Proxy :: Proxy Text)

-- | The CIP-129 id of a credential the @palmares@ views published as hex.
--
-- 'Nothing' when the text is not 28 bytes of hex, which cannot happen for a value read out of
-- @drep_hash.raw@ — so a decoder that gets 'Nothing' has found a view and a DTO disagreeing, and
-- should fail naming the field rather than publish something that is not an identifier.
drepIdFromHex :: Bool -> Text -> Maybe DRepId
drepIdFromHex hasScript hex = case B16.decode (TE.encodeUtf8 hex) of
  Right raw | BS.length raw == 28 -> Just (DRepId (drepIdCip129 hasScript raw))
  _ -> Nothing

-- | The 28-byte credential hash behind a 'DRepId', as hex.
--
-- This is what a handler looks a DRep up by. The script bit is deliberately NOT part of the
-- lookup, and that is measured rather than assumed: on preprod two hashes exist TWICE in
-- @drep_hash@, once as a key credential and once as a script credential, because someone
-- delegated using the CIP-105 string — which carries no script bit — and db-sync created the
-- other-kind row. In both cases exactly one of the pair is registered and the other is a phantom
-- with no certificate. Resolving by hash and preferring the registered row answers both
-- correctly; resolving by the normalised CIP-129 string would hit the phantom for one of them.
drepIdHex :: DRepId -> Maybe Text
drepIdHex (DRepId t)
  | t `Prelude.elem` reservedDRepViews = Nothing
  | otherwise = case parseDrepIdAny t of
      Right (_, raw) -> Just (TE.decodeUtf8 (B16.encode raw))
      Left _ -> Nothing

-- | The two reserved ledger voting options. They are not DReps — they hold no credential and
-- cannot vote — but they do hold stake, and @palmares.drep_epoch_power@ publishes them, so a
-- client may legitimately name one.
reservedDRepViews :: [Text]
reservedDRepViews = ["drep_always_abstain", "drep_always_no_confidence"]

-- | Accept all three credential forms a client may paste, plus the two reserved views.
--
-- NOTE for handlers: the script bit of a CIP-105 or raw-hex input cannot be known here, because
-- @drep@ is the HRP for both kinds and only the database knows which this credential is. This
-- instance therefore normalises an unflagged input to the KEY form, and a handler must look the
-- row up by the 28-byte hash through 'drepIdHex' — never by this string — and re-render the id
-- from the row's own @has_script@.
--
-- That is not a theoretical concern: see 'drepIdHex' for the two preprod credentials where
-- matching on the normalised string lands on a phantom row instead of the registered DRep.
instance FromHttpApiData DRepId where
  parseUrlPiece :: Text -> Either Text DRepId
  parseUrlPiece t
    | t `Prelude.elem` reservedDRepViews = Right (DRepId t)
    | otherwise = case parseDrepIdAny t of
        Right (mScript, raw) -> Right (DRepId (drepIdCip129 (fromMaybe False mScript) raw))
        Left _ -> Left "invalid_drep_id"

  parseQueryParam :: Text -> Either Text DRepId
  parseQueryParam = parseUrlPiece

-- | A governance action, canonically @\<proposal_tx_hash_hex\>#\<index\>@.
--
-- That form and not the CIP-129 bech32, because it is the form db-sync, cardano-cli and every
-- explorer print, and because it is readable in a URL. The bech32 is accepted on input.
newtype GovActionId = GovActionId {unGovActionId :: Text}
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON)

instance ToSchema GovActionId where
  declareNamedSchema _ = declareNamedSchema (Proxy :: Proxy Text)

instance ToParamSchema GovActionId where
  toParamSchema _ = toParamSchema (Proxy :: Proxy Text)

instance FromHttpApiData GovActionId where
  parseUrlPiece :: Text -> Either Text GovActionId
  parseUrlPiece t = case T.splitOn "#" t of
    [h, i]
      | T.length h == 64,
        T.all isHexDigit h,
        Just (ix, "") <- parseDecimal i ->
          Right (GovActionId (h <> "#" <> T.pack (show (ix :: Int))))
    [_] -> case parseGovActionIdCip129 t of
      Right (txId, ix) -> Right (GovActionId (txId <> "#" <> T.pack (show ix)))
      Left _ -> Left "invalid_gov_action_id"
    _ -> Left "invalid_gov_action_id"
    where
      parseDecimal s = case TRead.decimal s of
        Right r -> Just r
        Left _ -> Nothing

  parseQueryParam :: Text -> Either Text GovActionId
  parseQueryParam = parseUrlPiece

-- | The canonical id and the CIP-129 bech32 of a governance action, from the pair the
-- @palmares@ views publish: the proposal transaction's hash as hex, and its index.
--
-- Both forms go out. @\<tx_hash\>#\<index\>@ is what db-sync, cardano-cli and every explorer
-- print and is readable in a URL; the bech32 is what a CIP-129-aware wallet shows. Publishing one
-- and making the client derive the other would push a bech32 implementation into every consumer.
govActionIdForms :: Text -> Int -> Maybe (GovActionId, Text)
govActionIdForms txHex ix
  | ix < 0 || ix > 255 = Nothing
  | otherwise = case B16.decode (TE.encodeUtf8 txHex) of
      Right raw
        | BS.length raw == 32 ->
            Just
              ( GovActionId (txHex <> "#" <> T.pack (show ix)),
                govActionIdCip129 raw (fromIntegral ix)
              )
      _ -> Nothing

-- | The published identifier of a voter, by role, from the hash the views give as hex.
--
-- Three different forms on purpose, because each role's ecosystem shows a different one and
-- publishing a form nobody recognises makes the voter unsearchable:
--
--   * DRep — CIP-129 @drep1y…@;
--   * committee — CIP-129 @cc_cold1…@ over the COLD credential (D-24), the identity that survives
--     a hot-key rotation;
--   * stake pool — CIP-5 @pool1…@, which predates CIP-129 and is what cardano-cli and every
--     explorer show.
voterIdFor :: VoterRole -> Bool -> Text -> Maybe Text
voterIdFor role hasScript hex = case B16.decode (TE.encodeUtf8 hex) of
  Right raw
    | BS.length raw == 28 -> Just $ case role of
        DRep -> drepIdCip129 hasScript raw
        ConstitutionalCommittee -> ccColdIdCip129 hasScript raw
        SPO -> poolIdBech32 raw
  _ -> Nothing

-- | Where on the chain something happened.
--
-- @slot@ and @tx_hash@ are 'Nothing' together, for the events that have no transaction: a
-- governance action's ratification, enactment, expiry and drop all happen at an epoch boundary,
-- in the ledger, with no transaction to point at. Publishing a slot there would be publishing a
-- chain point no explorer could resolve.
data ChainPoint = ChainPoint
  { chainPointSlot :: Maybe Integer,
    chainPointEpoch :: Int,
    chainPointTime :: UTCTime,
    chainPointTxHash :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[FieldLabelModifier '[StripPrefix "chainPoint", CamelToSnake]] ChainPoint

instance ToSchema ChainPoint where
  declareNamedSchema = genericDeclareNamedSchema (mkStripPrefixSchemaOptions "chainPoint")

-- | A DRep's registration state, as @palmares.drep@ computes it.
--
-- @inactive@ is the one that surprises people: the ledger drops a DRep's voting power after
-- @drep_activity@ epochs without a vote, so a DRep can be registered, in good standing, and
-- powerless. @reserved@ is the two ledger options.
--
-- __@unknown@ is the third registered state, and it exists because we do not have the deadline for
-- every DRep.__ db-sync records the ledger's @active_until@ only in @drep_distr@, and @drep_distr@
-- holds a row only for a DRep the ledger included in that epoch's distribution. Measured on preprod
-- at epoch 320: __90 of 294 registered DReps have never had a row there__, at any epoch. Koios,
-- which computes the deadline itself, calls 21 of those 90 active and 69 inactive — so publishing
-- @inactive@ for all 90 stated something false about 21 real actors, and the obvious "unknown means
-- active" flip was implemented, measured and REVERTED, because it would be wrong for 69 to fix 21.
--
-- It is a __relabel, not new information__: @active_until_epoch@ has always been published and has
-- always been nullable, so those 90 were already identifiable as @inactive@ with a null deadline.
-- What changes is that the status field no longer carries a guess. @unknown@ is in the DEFAULT
-- status set, so the default page shows the same population it always did — 90 rows are renamed,
-- none appear and none disappear.
--
-- Deriving the deadline ourselves was measured and rejected: @max(last cert, last vote) +
-- drep_activity@ disagrees with the ledger's own value by up to 5 epochs, because CIP-1694 does not
-- count DORMANT epochs — ones with no proposal pending — toward inactivity. A second derivation that
-- can contradict the ledger is the thing this schema exists not to be.
--
-- @is_active@ beside this field stays a two-valued boolean and is NOT wrong for those 90: it means
-- "activity affirmed", which is the absence of a claim rather than the opposite claim. The
-- three-way distinction lives here.
data DRepStatus = DRepActive | DRepInactive | DRepUnknown | DRepRetired | DRepReserved
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "DRep", CamelToSnake]] DRepStatus

instance ToSchema DRepStatus where
  declareNamedSchema _ = pure (NamedSchema (Just "DRepStatus") (jsonEnumSchema (Proxy :: Proxy DRepStatus)))

instance ToParamSchema DRepStatus where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData DRepStatus where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | What a DRep certificate did. db-sync encodes this in the deposit column and nowhere else:
-- positive is a registration, negative a retirement, NULL a metadata update.
data DRepUpdateKind = UpdateKindRegistered | UpdateKindUpdated | UpdateKindRetired
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "UpdateKind", CamelToSnake]] DRepUpdateKind

instance ToSchema DRepUpdateKind where
  declareNamedSchema _ = pure (NamedSchema (Just "DRepUpdateKind") (jsonEnumSchema (Proxy :: Proxy DRepUpdateKind)))

instance ToParamSchema DRepUpdateKind where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData DRepUpdateKind where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | The seven CIP-1694 governance action types, spelled as db-sync's @govactiontype@ enum does.
--
-- @NewCommittee@, not @UpdateCommittee@: the ledger's own constructor name is
-- @UpdateCommittee@, but db-sync writes @NewCommittee@, and this registry's job is to publish
-- what the chain index holds rather than to rename it.
data GovActionType
  = ParameterChange
  | HardForkInitiation
  | TreasuryWithdrawals
  | NoConfidence
  | NewCommittee
  | NewConstitution
  | InfoAction
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] GovActionType

instance ToSchema GovActionType where
  declareNamedSchema _ = pure (NamedSchema (Just "GovActionType") (jsonEnumSchema (Proxy :: Proxy GovActionType)))

instance ToParamSchema GovActionType where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData GovActionType where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | A governance action's outcome, as @palmares.gov_action@ computes it.
--
-- The arms are ORDERED in the view because the lifecycle columns are not mutually exclusive: an
-- enacted action carries @ratified_epoch@ too, and most expired actions carry @dropped_epoch@.
-- State and votability can also disagree — an action with @expired_epoch@ equal to the current
-- epoch reads as @expired@ while its window is still open — so @palmares.action_window@, not
-- this value, decides whether a vote is still possible.
data GovActionState = Proposed | Ratified | Enacted | Expired | Dropped
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] GovActionState

instance ToSchema GovActionState where
  declareNamedSchema _ = pure (NamedSchema (Just "GovActionState") (jsonEnumSchema (Proxy :: Proxy GovActionState)))

instance ToParamSchema GovActionState where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData GovActionState where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | Who cast a vote.
--
-- The one enum where @CamelToSnake@ is wrong: it would produce @d_rep@ and @s_p_o@. The three
-- strings are written out, once, in the 'ConstructorTagModifier' — the Swagger enum and the
-- query parser both read them back from 'toJSON'.
data VoterRole = DRep | SPO | ConstitutionalCommittee
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON
          '[ ConstructorTagModifier
               '[ Rename "DRep" "drep",
                  Rename "SPO" "spo",
                  Rename "ConstitutionalCommittee" "constitutional_committee"
                ]
           ]
          VoterRole

instance ToSchema VoterRole where
  declareNamedSchema _ = pure (NamedSchema (Just "VoterRole") (jsonEnumSchema (Proxy :: Proxy VoterRole)))

instance ToParamSchema VoterRole where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData VoterRole where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | A vote, as cast. @abstain@ removes the voter's stake from the question rather than voting
-- against, which is why @palmares.vote_tally@ keeps it out of the denominator.
data Vote = Yes | No | Abstain
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[CamelToSnake]] Vote

instance ToSchema Vote where
  declareNamedSchema _ = pure (NamedSchema (Just "Vote") (jsonEnumSchema (Proxy :: Proxy Vote)))

instance ToParamSchema Vote where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData Vote where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | What a published tally is a tally OF, carried as a field on every tally so it can never be
-- mistaken for the ledger's ratification arithmetic.
--
-- @cast_votes_only@ means yes-power over (yes + no) power of the votes actually cast. The ledger
-- compares against TOTAL active voting power instead, which includes everyone who did not vote.
-- The two numbers differ, both are defensible, and only one of them is what we computed.
-- 'TagSingleConstructors' is load-bearing, not decoration: with one nullary constructor aeson
-- treats the type as a non-sum and encodes it as @[]@, an empty ARRAY, because
-- @tagSingleConstructors@ defaults to False. Measured — that is what this type shipped as until a
-- golden test caught it.
data TallyBasis = CastVotesOnly
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON '[TagSingleConstructors, ConstructorTagModifier '[CamelToSnake]] TallyBasis

instance ToSchema TallyBasis where
  declareNamedSchema _ = pure (NamedSchema (Just "TallyBasis") (jsonEnumSchema (Proxy :: Proxy TallyBasis)))

-- | What became of a metadata anchor, consumed verbatim from @palmares.anchor@.
--
-- Seven values, and the last two are the ones that keep the published rationale rate honest:
-- @inline@ is a @data:@ URI, where the rationale IS the URL and hash verification is vacuous, and
-- @not_fetched@ means db-sync has not tried yet, which is not the author's failure.
data AnchorStatus
  = AnchorValid
  | AnchorInvalidSchema
  | AnchorHashMismatch
  | AnchorOversized
  | AnchorUnreachable
  | AnchorInline
  | AnchorNotFetched
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "Anchor", CamelToSnake]] AnchorStatus

instance ToSchema AnchorStatus where
  declareNamedSchema _ = pure (NamedSchema (Just "AnchorStatus") (jsonEnumSchema (Proxy :: Proxy AnchorStatus)))

instance ToParamSchema AnchorStatus where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData AnchorStatus where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | Which feed an activity row came from.
--
-- One value in Plan A, because @palmares.activity@ emits exactly one. Attestations arrive as
-- their own source when Plan B lands, which is a new enum value on an existing field — a minor
-- Swagger bump, not a rewrite.
data ActivitySource = SourceGovernance
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON)
    via CustomJSON
          '[TagSingleConstructors, ConstructorTagModifier '[StripPrefix "Source", CamelToSnake]]
          ActivitySource

instance ToSchema ActivitySource where
  declareNamedSchema _ = pure (NamedSchema (Just "ActivitySource") (jsonEnumSchema (Proxy :: Proxy ActivitySource)))

instance ToParamSchema ActivitySource where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData ActivitySource where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | The thirteen kinds of thing the governance feed reports, matching
-- @palmares.activity.event_type@ one for one.
--
-- Two of them are unreachable on preprod — no committee has ever resigned and no treasury
-- withdrawal has ever been enacted there — which is why the thirteen-value assertion lives in a
-- seeded unit test rather than in a check against live data.
data ActivityEventType
  = EvtDrepRegistered
  | EvtDrepUpdated
  | EvtDrepRetired
  | EvtDelegationChanged
  | EvtVoteCast
  | EvtGovActionProposed
  | EvtGovActionRatified
  | EvtGovActionEnacted
  | EvtGovActionExpired
  | EvtGovActionDropped
  | EvtCommitteeAuthorized
  | EvtCommitteeResigned
  | EvtTreasuryWithdrawalEnacted
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "Evt", CamelToSnake]] ActivityEventType

instance ToSchema ActivityEventType where
  declareNamedSchema _ = pure (NamedSchema (Just "ActivityEventType") (jsonEnumSchema (Proxy :: Proxy ActivityEventType)))

instance ToParamSchema ActivityEventType where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData ActivityEventType where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | The groups @\/search@ returns, one per result group in the response.
--
-- @profile@ and @attestation@ exist and serve empty in Plan A: the palette renders six groups,
-- and a kind a client cannot name is a kind it cannot filter to once Plan B fills it.
-- @stake_address@ is deliberately absent — the response record has no group for it.
data SearchKind
  = SearchDrep
  | SearchGovAction
  | SearchSpo
  | SearchCommitteeMember
  | SearchProfile
  | SearchAttestation
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "Search", CamelToSnake]] SearchKind

instance ToSchema SearchKind where
  declareNamedSchema _ = pure (NamedSchema (Just "SearchKind") (jsonEnumSchema (Proxy :: Proxy SearchKind)))

instance ToParamSchema SearchKind where
  toParamSchema = jsonEnumParamSchema

instance FromHttpApiData SearchKind where
  parseUrlPiece = parseJsonEnumParam "invalid_parameter"

-- | A committee member's standing, as @palmares.committee_member@ computes it.
--
-- Two values, not Koios's four. Our view derives the status from
-- @committee_de_registration@ alone, and expiry is published as @expiration_epoch@ beside it
-- rather than folded in — a member whose term ends next epoch is still serving today. The
-- Koios-facing mapping belongs to the parity work, which reads Koios's own value set first.
data CommitteeMemberStatus = CommitteeActive | CommitteeResigned
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving (FromJSON, ToJSON) via CustomJSON '[ConstructorTagModifier '[StripPrefix "Committee", CamelToSnake]] CommitteeMemberStatus

instance ToSchema CommitteeMemberStatus where
  declareNamedSchema _ =
    pure (NamedSchema (Just "CommitteeMemberStatus") (jsonEnumSchema (Proxy :: Proxy CommitteeMemberStatus)))

instance ToParamSchema CommitteeMemberStatus where
  toParamSchema = jsonEnumParamSchema

-- | The 28 raw bytes behind a credential hash the @palmares@ views published as hex.
--
-- 'Nothing' when it is not 28 bytes of hex, which cannot happen for a value read out of a @raw@
-- column — so a decoder that gets 'Nothing' has found a view and a DTO disagreeing. Factored out
-- of 'drepIdFromHex' and 'voterIdFor', which did the same decode privately, because 'SPOSummary'
-- and 'CommitteeMemberSummary' need the bytes to render a @pool1…@ and a @cc_cold1…@.
decodeHash28 :: Text -> Maybe BS.ByteString
decodeHash28 hex = case B16.decode (TE.encodeUtf8 hex) of
  Right raw | BS.length raw == 28 -> Just raw
  _ -> Nothing
