{-# LANGUAGE OverloadedStrings #-}

-- | Shared utilities for web API executables (port configuration, Swagger helpers, etc.).
module Palmares.WebAPI.Utils
  ( getPortFromEnvOrDefault
  , addSharedSwaggerDescriptions
  , escapeLikePattern
  ) where

import Control.Lens ((&), (?~), at, mapped)
import Data.Swagger (Swagger, description, definitions)
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Read the @PORT@ environment variable, falling back to the given default if unset or unparseable.
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
       \such as a working-group lead or committee chair, usually with a claimed period), endorsement. \
       \No validator branches on it: the kind says what a reader is being told, not what the protocol \
       \permits."
