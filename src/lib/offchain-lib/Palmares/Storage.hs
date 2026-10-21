{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Persistent storage layer for chain-sync projections, cursor management, and rollback.
module Palmares.Storage where

import Control.Monad (forM_, void)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Int (Int64)
import Data.List qualified as L
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Database.Persist
import Database.Persist.Sql
import Database.Persist.TH
import Palmares.DomainTypes.Core.Types
import GeniusYield.Types
import Palmares.Ingestion
import Palmares.ChainSync.KupoAtlas (kupoMatchToAtlasMatch)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..))

derivePersistFieldJSON "GYAssetClass"

-- | Persist 'Integer' columns (chain slots, interval numbers) as PostgreSQL @bigint@ so SQL
-- comparisons and @ORDER BY@ are numeric, not lexicographic. Cardano slots are ~10^9, far under
-- 'Int64' range; the overflow guard is defensive and unreachable for real slot/interval values.
instance PersistField Integer where
  toPersistValue i
    | i >= toInteger (minBound :: Int64) && i <= toInteger (maxBound :: Int64) =
        PersistInt64 (fromInteger i)
    | otherwise = error "Storage: Integer out of Int64 range for bigint persistence"
  fromPersistValue (PersistInt64 n) = Right (toInteger n)
  fromPersistValue x = Left ("Expected PersistInt64 for Integer, got: " <> Text.pack (show x))

instance PersistFieldSql Integer where
  sqlType _ = SqlInt64

-- | Custom PersistField for GYTime stored as @timestamptz@ in PostgreSQL.
-- Converts via UTCTime so the column type matches the parameter type,
-- avoiding @varchar >= timestamptz@ mismatches in SQL comparisons.
-- Reads back both @PersistUTCTime@ (native timestamptz) and @PersistText@
-- (legacy rows written before this change) for backward compatibility.
instance PersistField GYTime where
  toPersistValue gt =
    PersistUTCTime $ posixSecondsToUTCTime (timeToPOSIX gt)
  fromPersistValue (PersistUTCTime utc) =
    Right $ timeFromPOSIX (utcTimeToPOSIXSeconds utc)
  fromPersistValue (PersistText t) =
    case gyIso8601ParseM (Text.unpack (stripQuotes t)) of
      Just gt -> Right gt
      Nothing -> Left $ "Cannot parse GYTime from: " <> t
    where
      -- Handle legacy data stored via derivePersistFieldJSON with surrounding quotes
      stripQuotes s
        | Just rest <- Text.stripPrefix "\"" s, Just inner <- Text.stripSuffix "\"" rest = inner
        | otherwise = s
  fromPersistValue x = Left $ "Expected PersistUTCTime or PersistText for GYTime, got: " <> Text.pack (show x)

instance PersistFieldSql GYTime where
  sqlType _ = SqlDayTime

-- Persistent entities for chain sync state and events.
-- We store a singleton cursor row keyed by a Unique flag to always upsert/update the same row.

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
ChainCursor
    singleton        Bool
    slotNo           Integer
    headerHash       Text
    lastTxId         Text Maybe
    lastOutputIndex  Int  Maybe
    UniqueCursor singleton
    deriving Show

-- Singleton config row: stored minting policy hex; used only at startup to detect policy change and optionally wipe.
ChainSyncConfig
    singleton        Bool
    policyHexText    Text
    schemaVersion    Int default=1
    UniqueChainSyncConfig singleton
    deriving Show

-- Raw Atlas match storage (flattened Kupo match fields)
OnchainMatchEvent
    createdSlot        Integer
    createdHeader      Text
    createdTxId        Text
    createdTxIndex     Int
    createdOutputIndex Int
    kupoMatch          KupoMatch
    UniqueKupoMatch createdSlot createdHeader createdTxId createdOutputIndex
    deriving Show

-- Projection-specific flattened tables (domain fields + created_at).
-- Inherited fix #5: @createdAtSlot@ is the ONLY time a projection row carries. A wall clock
-- stamped at ingest is re-stamped by every 'rollbackTo' + replay, which silently renumbers
-- anything ordered by it; the chain's slot is immune to replay. Readers convert with
-- 'Palmares.TxBuilding.Utils.slotToUTC'.
ProfileProjection
    createdAtSlot    Integer
    createdAtHash    Text
    profileId        GYAssetClass
    profileName      Text
    profileDescription Text
    profileImageURI  Text
    profileType      ProfileType
    UniqueProfileProjection profileId
    deriving Show

AttestationProjection
    createdAtSlot             Integer
    createdAtHash             Text
    createdTxId               Text
    createdOutputIndex        Int
    attestationId             GYAssetClass
    subjectProfileId        GYAssetClass
    issuerProfileId        GYAssetClass
    attestationDate           GYTime
    isAccepted                Bool
    attestationName           Text
    attestationDescription    Text
    attestationImageURI       Text
    otherMetadata             (Maybe AttestationOtherMetadataJson)
    UniqueAttestationProjection attestationId
    deriving Show
|]

-- | The schema this service owns, and the only one it may write.
--
-- __Why this is a named constant and not a comment.__ Every entity in the @persistLowerCase@ block
-- above is declared unqualified, so @migrateAll@'s @CREATE TABLE@ lands in whatever the connection's
-- @search_path@ resolves to first. Nothing in this service used to set that path, and
-- @sql/050_roles.sql@ gives @palmares_owner@ @search_path = palmares, palmares_attest, public@ — so
-- the projections landed in @palmares@, which @sql/000_schema.sql@ __drops CASCADE on every
-- query-api boot__. A restart of the read API would have deleted the chain-sync state and cost a
-- full Kupo re-sync, silently. (@sql/000_schema.sql@'s own header warns against dropping
-- @palmares_attest@ for exactly this reason, while the tables were not in it.)
attestSchema :: Text
attestSchema = "palmares_attest"

-- | Create 'attestSchema' if it is absent, so a fresh database needs no manual step.
--
-- @admin apply-roles@ also creates it, @AUTHORIZATION palmares_owner@; this is the path for a
-- single-role deployment that never ran that command. Idempotent either way.
ensureAttestSchema :: (MonadIO m) => SqlPersistT m ()
ensureAttestSchema = rawExecute ("CREATE SCHEMA IF NOT EXISTS " <> attestSchema) []

-- | Run an action with @search_path@ pinned to 'attestSchema', then @public@.
--
-- Every database access in this service goes through here, which is what makes the unqualified
-- entity declarations safe. @SET LOCAL@ scopes it to the transaction @runSqlPool@ opens, so it
-- cannot leak onto a pooled connection that some other code path later reuses — the same shape
-- query-api uses for its read timeout.
--
-- @public@ stays on the path because @GYAssetClass@ and friends resolve enum and domain types
-- db-sync owns, and because 'readSchemaProbe' filters on @current_schema()@, which is the first
-- entry and therefore ours.
runAttest :: ConnectionPool -> SqlPersistT IO a -> IO a
runAttest pool act = runSqlPool (pinSearchPath >> act) pool
  where
    pinSearchPath = rawExecute ("SET LOCAL search_path TO " <> attestSchema <> ", public") []

runMigrations :: (MonadIO m) => SqlPersistT m ()
runMigrations = runMigration migrateAll

-- | Bump when the chain-sync DB schema changes incompatibly; startup wipes + re-syncs on a mismatch.
-- v1: first schema of this registry (profile + attestation projections). Nothing is deployed yet, so
-- the inherited v4 history does not carry over.
currentSchemaVersion :: Int
currentSchemaVersion = 1

-- | Upsert a record by its unique key: insert if absent, replace if present.
upsertByUnique ::
  (PersistEntity a, PersistEntityBackend a ~ SqlBackend, SafeToInsert a, MonadIO m) =>
  (a -> Unique a) ->
  a ->
  SqlPersistT m ()
upsertByUnique getUnique val = do
  mExisting <- getBy (getUnique val)
  case mExisting of
    Nothing -> void (insert val)
    Just (Entity key _) -> replace key val

-- Fetch current cursor if exists
getCursorValue :: (MonadIO m) => SqlPersistT m (Maybe ChainCursor)
getCursorValue = fmap entityVal <$> getBy (UniqueCursor True)

-- Upsert the singleton cursor
putCursor :: (MonadIO m) => ChainCursor -> SqlPersistT m ()
putCursor = upsertByUnique (const (UniqueCursor True))

-- | Upsert the singleton config row with the given policy hex and the current schema version.
putStoredPolicyHexText :: (MonadIO m) => Text -> SqlPersistT m ()
putStoredPolicyHexText policyHexText =
  upsertByUnique (const (UniqueChainSyncConfig True)) (ChainSyncConfig True policyHexText currentSchemaVersion)

-- | Table names for all entities in this persist block (persistLowerCase).
-- When adding a new entity to this block, add its table name here so wipeChainSyncTablesRaw drops it.
chainSyncTableNames :: [Text]
chainSyncTableNames =
  [ "attestation_projection",
    "chain_cursor",
    "chain_sync_config",
    "onchain_match_event",
    "profile_projection"
  ]

-- | Drop all chain-sync tables WITHOUT re-migrating (migration happens separately, after this).
wipeChainSyncTablesRaw :: (MonadIO m) => SqlPersistT m ()
wipeChainSyncTablesRaw =
  forM_ chainSyncTableNames $ \tableName ->
    rawExecute ("DROP TABLE IF EXISTS " <> tableName <> " CASCADE") []

-- | Read (schemaVersion, policyHex) from an existing @chain_sync_config@ via raw SQL, tolerant of the
-- table or the @schema_version@ column being absent (pre-fix DBs). Returns 'Nothing' if the table does
-- not exist (fresh install). A pre-fix table without the column reports version 1.
readSchemaProbe :: (MonadIO m) => SqlPersistT m (Maybe (Int, Text))
readSchemaProbe = do
  tbl <-
    rawSql
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables \
      \WHERE table_name = 'chain_sync_config' AND table_schema = current_schema())"
      []
  case tbl of
    [Single True] -> do
      col <-
        rawSql
          "SELECT EXISTS (SELECT 1 FROM information_schema.columns \
          \WHERE table_name = 'chain_sync_config' AND column_name = 'schema_version' \
          \AND table_schema = current_schema())"
          []
      case col of
        [Single True] -> do
          rows <- rawSql "SELECT schema_version, policy_hex_text FROM chain_sync_config LIMIT 1" []
          pure $ case rows of
            [(Single v, Single p)] -> Just (v, p)
            _ -> Just (1, "")
        _ -> do
          rows <- rawSql "SELECT policy_hex_text FROM chain_sync_config LIMIT 1" []
          pure $ case rows of
            [Single p] -> Just (1, p)
            _ -> Just (1, "")
    _ -> pure Nothing

-- | Store a raw Kupo match and its derived projections.
putMatchAndProjections :: (MonadIO m) => GYNetworkId -> KupoMatch -> SqlPersistT m ()
putMatchAndProjections networkId km = do
  putKupoMatch km
  projectAndStore networkId km

-- | Derive and store the projections for a raw match (does NOT re-store the raw match). Reused by
-- 'rollbackTo' to replay the surviving log. Conversion/projection failures are logged and skipped.
-- TODO(stream ?): dead-letter table for replayable failed projections.
projectAndStore :: (MonadIO m) => GYNetworkId -> KupoMatch -> SqlPersistT m ()
projectAndStore networkId km =
  case kupoMatchToAtlasMatch km of
    Left convErr -> liftIO $ putStrLn ("PROJECTION ERROR (dropped, raw match retained): conversion error: " <> convErr)
    Right am -> do
      let slotNoInt = slot_no (created_at km)
          header = header_hash (created_at km)
          txId = transaction_id km
          outIdx = output_index km
      ev <- runExceptT (projectChainEvent networkId am)
      case ev of
        Left e -> liftIO $ putStrLn ("PROJECTION ERROR (dropped, raw match retained): " <> show e)
        Right proj -> case proj of
          ProfileEvent p -> putProfileProjection slotNoInt header p
          AttestationEvent a -> putAttestationProjection slotNoInt header txId outIdx a
          NoEvent _ -> pure ()

-- | Store a raw Kupo match event, upserting by (slot, header, txId, outputIndex) — the on-chain
-- identity of the output, so multiple matches in the same block no longer overwrite each other.
putKupoMatch :: (MonadIO m) => KupoMatch -> SqlPersistT m ()
putKupoMatch km = do
  let cSlot = slot_no (created_at km)
      cHash = header_hash (created_at km)
      ev = OnchainMatchEvent cSlot cHash (transaction_id km) (transaction_index km) (output_index km) km
  upsertByUnique
    ( \e ->
        UniqueKupoMatch
          (onchainMatchEventCreatedSlot e)
          (onchainMatchEventCreatedHeader e)
          (onchainMatchEventCreatedTxId e)
          (onchainMatchEventCreatedOutputIndex e)
    )
    ev

-- | Store a profile projection, upserting by profile ID.
putProfileProjection :: (MonadIO m) => Integer -> Text -> Profile -> SqlPersistT m ()
putProfileProjection createdSlot createdHash p = do
  let ev =
        ProfileProjection
          createdSlot
          createdHash
          (profileId p)
          (profileName p)
          (profileDescription p)
          (profileImageURI p)
          (profileType p)
  upsertByUnique (UniqueProfileProjection . profileProjectionProfileId) ev

-- | Store an attestation projection, upserting by attestation ID.
putAttestationProjection :: (MonadIO m) => Integer -> Text -> Text -> Int -> Attestation -> SqlPersistT m ()
putAttestationProjection createdSlot createdHash createdTxId createdOutIdx a = do
  let ev =
        AttestationProjection
          createdSlot
          createdHash
          createdTxId
          createdOutIdx
          (attestationId a)
          (attestationSubjectProfileId a)
          (attestationIssuerProfileId a)
          (attestationAttestationDate a)
          (attestationAccepted a)
          (attestationName a)
          (attestationDescription a)
          (attestationImageURI a)
          (Just $ AttestationOtherMetadataJson $ attestationOtherMetadata a)
  upsertByUnique (UniqueAttestationProjection . attestationProjectionAttestationId) ev

-- | The single source of chain-replay order: sort raw matches by true chain order
-- @(slot, transaction_index, output_index)@. Used by 'rollbackTo' and by tests.
replayOrder :: [OnchainMatchEvent] -> [OnchainMatchEvent]
replayOrder =
  L.sortOn
    ( \e ->
        ( onchainMatchEventCreatedSlot e,
          onchainMatchEventCreatedTxIndex e,
          onchainMatchEventCreatedOutputIndex e
        )
    )

-- | Roll back to @slot@: discard raw matches beyond it, wipe the derived projection tables, and
-- rebuild them by replaying the surviving raw-match log in chain order. Correct because callers pass
-- a slot strictly below any orphan (guaranteed by the F-08 rollback margin >= 1).
rollbackTo :: (MonadIO m) => GYNetworkId -> Integer -> SqlPersistT m ()
rollbackTo networkId slot = do
  -- 1. Discard raw matches strictly beyond the rollback slot (numeric compare; F-02 fixed).
  deleteWhere [OnchainMatchEventCreatedSlot >. slot]
  -- 2. Wipe all derived projection tables.
  deleteWhere ([] :: [Filter ProfileProjection])
  deleteWhere ([] :: [Filter AttestationProjection])
  -- 3. Replay surviving raw matches in true chain order.
  surviving <- selectList [] []
  mapM_ (projectAndStore networkId . onchainMatchEventKupoMatch) (replayOrder (map entityVal surviving))
