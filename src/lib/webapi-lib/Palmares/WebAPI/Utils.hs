{-# LANGUAGE OverloadedStrings #-}

-- | Shared utilities for web API executables (port configuration, Swagger helpers, etc.).
module Palmares.WebAPI.Utils
  ( getPortFromEnvOrDefault
  , requirePgConnStr
  , requireEnv
  , addSharedSwaggerDescriptions
  , markNullableFields
  , escapeLikePattern
  ) where

import Control.Lens ((&), (?~), at, mapped)
import Data.Aeson (Value (Array, Bool, Object, String))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Swagger (Swagger, description, definitions)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (die)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Read the @PORT@ environment variable, falling back to the given default if unset or unparseable.
-- | The Postgres DSN from @PG_CONN_STR@, or refuse to boot — `TD-09`.
--
-- __What stood in each executable was a DEFAULT, and the default was a superuser with a guessable
-- password:__ @user=postgres password=postgres@. An operator who set every other variable and forgot
-- this one got a service silently connected as the database superuser — or, far likelier in a
-- cluster, a connection refused with no hint that the DSN had never been configured.
--
-- Fail-closed, the same rule @BASIC_USER@ and @CORS_ALLOWED_ORIGINS@ already follow: a wrong
-- configuration that works is worse than one that stops, because only one of the two gets fixed.
--
-- Here rather than in each executable because both query-api and attest-sync had their own copy of
-- the default, with different hosts and the same password, which is how one of them could be fixed
-- and the other not.
requirePgConnStr :: IO String
requirePgConnStr =
  requireEnv' "PG_CONN_STR" "Set the Postgres DSN for this service."

-- | Any environment variable that must not have a default, with the reason in the refusal.
--
-- The generalisation of 'requirePgConnStr', and it exists because the rule had been applied one
-- variable at a time: @KUPO_URL@ still defaulted to @http:\/\/localhost:1442@ on the one service
-- whose whole job is reading the chain, at a port no deployment in this repo uses.
requireEnv :: String -> IO String
requireEnv name = requireEnv' name "It has no default: a wrong configuration that works is worse than one that stops."

requireEnv' :: String -> String -> IO String
requireEnv' name hint = do
  mv <- lookupEnv name
  case mv of
    Just v | not (null v) -> pure v
    _ -> die (name <> " is required and has no default. " <> hint)

getPortFromEnvOrDefault :: Int -> IO Int
getPortFromEnvOrDefault defaultPort = do
  eport <- lookupEnv "PORT"
  case eport of
    Nothing -> return defaultPort
    Just p -> case readMaybe p of
      Just n -> return n
      Nothing -> do
        putStrLn $ "Warning: invalid PORT value; defaulting to " <> show defaultPort
        return defaultPort

-- | Escape SQL @LIKE@ metacharacters in user-supplied search text so that
-- @%@ and @_@ match literally. Backslash is escaped first (it is the escape
-- character). Relies on PostgreSQL's default @LIKE@ escape character (@\\@);
-- esqueleto's @like@ emits no explicit @ESCAPE@ clause.
escapeLikePattern :: Text -> Text
escapeLikePattern =
  T.replace "_" "\\_"
    . T.replace "%" "\\%"
    . T.replace "\\" "\\\\"

-- | Publish every @Maybe@ field as nullable, by adding @x-nullable: true@ to its property schema.
--
-- __Why this is a pass over the encoded document and not a 'Data.Swagger.SchemaOptions' setting.__
-- swagger2's @Schema@ record (2.8.9, @Data.Swagger.Internal@) has no extension field at all — the
-- constructor is title\/description\/required\/allOf\/properties\/additionalProperties\/
-- discriminator\/readOnly\/xml\/externalDocs\/example\/maxProperties\/minProperties\/paramSchema and
-- nothing else — so there is no value of any swagger2 type that encodes an @x-@ key, and
-- @SchemaOptions@ carries only the four name modifiers. The alternative to this pass is a
-- hand-written @ToSchema@ instance per DTO that post-processes its own properties, which is 60-odd
-- instances to say one thing.
--
-- __What makes it correct rather than a guess: absence from @required@ IS the @Maybe@.__
-- @genericDeclareNamedSchema@ puts a record field in @required@ unless its type is @Maybe a@ — that
-- is the only thing that takes a field out of the list — so the document already carries the
-- distinction and this pass copies it into the one key a client codegen reads. Verified by value on
-- the committed document: @StatusResponse.required@ names five of its nine properties, and the four
-- it omits (@attest_lag_seconds@, @attestation@, @drep_distr_epoch@, @metrics_as_of_epoch@) are
-- exactly the four @Maybe@ fields of the Haskell record.
--
-- __Why it matters.__ In Swagger 2.0 absence from @required@ permits the key to be OMITTED; it does
-- not sanction a @null@ value. Every encoder in this repo always EMITS the key, with @null@ — the
-- shape @UnitTests.GovDto@ pins — so a generated TypeScript client typed those fields as
-- non-optional and non-null and threw on the first row that had one. 127 properties across 61
-- definitions were in that state, @DRepSummary.given_name@ and @Page.total@ among them.
--
-- __The one case this cannot express, stated rather than hidden.__ 15 of the 127 are a bare
-- @{"$ref": …}@ (@StatusResponse.attestation@, @DisputeRow.verdict@, @VoteRecord.anchor@, …), and a
-- Swagger 2.0 reader is entitled to ignore any sibling of @$ref@ — the same limit
-- 'addSharedSwaggerDescriptions' records for @AttestationType@'s description. The key is written
-- anyway, because the generators that read @x-nullable@ at all read it there too, and because the
-- alternative — rewriting each into @{"x-nullable": true, "allOf": [{"$ref": …}]}@ — changes the
-- shape of 15 properties in the frontend's codegen input to fix a case where a @null@ is a whole
-- absent object rather than a field inside a row. If a generator is ever shown to need the wrapper,
-- it belongs here, in this function, and nowhere else.
--
-- The walk is recursive and keyed on @type: "object"@ plus a @properties@ object, so it also covers
-- an inline schema under @paths@ if one ever appears (today there are none: measured, every object
-- with @properties@ in the document is under @definitions@). The @type@ guard is what keeps a DTO
-- field that happens to be NAMED @properties@ or @required@ from being read as schema structure —
-- a property's value is always a schema object, never the string @"object"@.
markNullableFields :: Value -> Value
markNullableFields = go
  where
    go (Object o) = Object (markProperties (KM.map go o))
    go (Array xs) = Array (fmap go xs)
    go v = v

    markProperties o
      | Just (String "object") <- KM.lookup "type" o,
        Just (Object props) <- KM.lookup "properties" o =
          KM.insert "properties" (Object (KM.mapWithKey (markUnlessRequired (requiredNames o)) props)) o
      | otherwise = o

    requiredNames o = case KM.lookup "required" o of
      Just (Array rs) -> [t | String t <- toList rs]
      _ -> []

    markUnlessRequired req k v
      | Key.toText k `elem` req = v
      | Object p <- v = Object (KM.insert "x-nullable" (Bool True) p)
      -- A property schema is always an object in a swagger2-generated document; anything else is
      -- left exactly as it was rather than wrapped, because this pass must not be the thing that
      -- invents a schema.
      | otherwise = v

-- | Add descriptions to shared Cardano/domain type definitions in a Swagger spec.
-- Call this in both interaction-api and query-api to keep descriptions consistent.
addSharedSwaggerDescriptions :: Swagger -> Swagger
addSharedSwaggerDescriptions s = s
  & definitions . at "GYAssetClass" . mapped . description ?~ "Cardano native asset identifier in format: <56-char policy ID hex>.<asset name hex>"
  -- RAW CBOR HEX, and this line used to say bech32. Atlas's `FromJSON GYAddress` is
  -- `parseUrlPiece`, i.e. `deserialiseFromRawBytesHex`, so `addr_test1…` is REFUSED on every write
  -- route — while the same definition carries Atlas's own `format: cbor hex`, `minLength`/
  -- `maxLength` 114 and a 114-character hex example. The document contradicted itself and the
  -- sentence a reader trusts was the wrong half: an integrator following it got a 400 on every
  -- write. `scripts/smoke_attest_flow.sh` and `smoke_interaction_api.sh` both send the hex form.
  & definitions . at "GYAddress" . mapped . description ?~ "Cardano address as RAW CBOR HEX (114 hex characters), not bech32: this field is parsed with deserialiseFromRawBytesHex, so addr_test1…/addr1… is refused. `admin operator-address` prints the hex form."
  & definitions . at "GYTime" . mapped . description ?~ "Timestamp in ISO 8601 format (e.g. 2024-06-15T10:30:00Z)"
  & definitions . at "GYPubKeyHash" . mapped . description ?~ "Blake2b-224 public key hash, 28 bytes, hex-encoded"
  & definitions . at "DRepId" . mapped . description ?~ "DRep identifier. CIP-129 bech32 (drep1...) is canonical; the CIP-105 and raw-hex forms are also accepted on input"
  & definitions . at "GovActionId" . mapped . description ?~ "Governance action identifier: CIP-129 bech32 (gov_action1...) over the 32-byte proposal tx id and its 1-byte index"
  -- This row predated the type by a long way, and the `at` lens was a silent no-op the whole time:
  -- there was no AttestationType in the repo, so the key matched nothing. It is also the ONLY place
  -- this description can live — the request property is a bare `$ref`, and a Swagger 2.0 $ref cannot
  -- carry a sibling description.
  & definitions . at "AttestationType" . mapped . description
    ?~ "What an attestation asserts about its subject: milestone_delivered (a budget administrator \
       \attests a vendor's delivery), audit_passed (an auditor attests it reviewed one), affiliation \
       \(organisation to member, usually with a claimed period), role_held (an extra-chain mandate \
       \such as a working-group lead or committee chair, usually with a claimed period), endorsement, \
       \credential_claim (a profile binds itself to a Cardano governance credential, which is what \
       \the `credential` field of a profile is derived from) and credential_withdrawal (that binding \
       \ended). \
       \For the first five the kind is presentational: it says what a reader is being told, not what \
       \the protocol permits. The last two the protocol does enforce — they must be self-issued and \
       \must name a credential that proved control of the minting transaction, and the first five \
       \must name none."
