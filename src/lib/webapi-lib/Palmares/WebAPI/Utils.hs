{-# LANGUAGE OverloadedStrings #-}

-- | Shared utilities for web API executables (port configuration, Swagger helpers, etc.).
module Palmares.WebAPI.Utils
  ( getPortFromEnvOrDefault
  , requirePgConnStr
  , addSharedSwaggerDescriptions
  , escapeLikePattern
  ) where

import Control.Lens ((&), (?~), at, mapped)
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
requirePgConnStr = do
  mv <- lookupEnv "PG_CONN_STR"
  case mv of
    Just v | not (null v) -> pure v
    _ -> die "PG_CONN_STR is required and has no default. Set the Postgres DSN for this service."

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

-- | Add descriptions to shared Cardano/domain type definitions in a Swagger spec.
-- Call this in both interaction-api and query-api to keep descriptions consistent.
addSharedSwaggerDescriptions :: Swagger -> Swagger
addSharedSwaggerDescriptions s = s
  & definitions . at "GYAssetClass" . mapped . description ?~ "Cardano native asset identifier in format: <56-char policy ID hex>.<asset name hex>"
  & definitions . at "GYAddress" . mapped . description ?~ "Bech32-encoded Cardano address (addr_test1... on testnet, addr1... on mainnet)"
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
