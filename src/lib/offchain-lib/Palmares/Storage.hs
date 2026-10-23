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

-- | Stored the way 'ProfileType' and 'AttestationType' are — through the enum's own JSON, which is
-- the one place its wire spelling is written. Here rather than beside the type because
-- "Palmares.DomainTypes.Core.Types" holds no @persistent@ import and this is the only writer.
derivePersistFieldJSON "DisputeVerdict"

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
--
-- profileCredential is the CIP-129 rendering of the credential the datum claims, and it carries
-- NO unique constraint on purpose: a credential may be claimed by two profiles and the read layer
-- reports that as `contested` rather than the ingest path refusing the second claim. A unique
-- index here would make the losing claim invisible instead of visible-and-flagged, which is the
-- opposite of what the registry is for. 'runMigrations' adds the plain index.
ProfileProjection
    createdAtSlot    Integer
    createdAtHash    Text
    profileId        GYAssetClass
    profileName      Text
    profileDescription Text
    profileImageURI  Text
    profileType      ProfileType
    profileCredential Text Maybe
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
    attestationKind           AttestationType
    attestationCredential     (Maybe Text)
    attestationDate           GYTime
    claimedPeriodFrom         (Maybe GYTime)
    claimedPeriodTo           (Maybe GYTime)
    isAccepted                Bool
    attestationName           Text
    attestationDescription    Text
    attestationImageURI       Text
    otherMetadata             (Maybe AttestationOtherMetadataJson)
    UniqueAttestationProjection attestationId
    deriving Show

-- A dispute is its own UTxO pointing at an attestation and never a field on one, so it is its own
-- table: an upheld dispute is published BESIDE the attestation it contests and never hides or
-- deletes it (spec 4.3). @verdict@ is NULL while the dispute is open.
DisputeProjection
    createdAtSlot        Integer
    createdAtHash        Text
    disputeId            GYAssetClass
    targetAttestationId  GYAssetClass
    openedByProfileId    GYAssetClass
    openedAt             GYTime
    deposit              Integer
    verdict              (Maybe DisputeVerdict)
    disputeName          Text
    disputeDescription   Text
    disputeImageURI      Text
    UniqueDisputeProjection disputeId
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

-- | The attestation projector's own chain position, in slots, read from __outside__ this service.
--
-- @Nothing@ means the projector has never run against this database: either 'ChainCursor' does not
-- exist yet, or the reading role cannot see it. Both are the same statement to a caller — "no
-- evidence" — and deliberately not the same as "behind", because a reader that turned absence into
-- a failure would take a governance-only deployment permanently out of rotation.
--
-- __Why a probe and not a column on @palmares.sync_state@.__ That view is created by
-- @sql/010_gov_views.sql@ on every query-api boot, right after @sql/000_schema.sql@ drops and
-- recreates the @palmares@ schema. PostgreSQL resolves a view's identifiers when the view is
-- created, so a reference to @palmares_attest.chain_cursor@ would make query-api's boot fail
-- outright on any database where this service has not run yet. The probe cannot: it asks the
-- catalog first.
--
-- The table is named with its schema rather than through @search_path@, because the caller is
-- query-api, whose path is its own.
attestCursorSlot :: (MonadIO m) => SqlPersistT m (Maybe Integer)
attestCursorSlot = do
  tbl <-
    rawSql
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables \
      \WHERE table_name = 'chain_cursor' AND table_schema = ?)"
      [toPersistValue attestSchema]
  case tbl of
    [Single True] -> do
      rows <- rawSql ("SELECT slot_no FROM " <> attestSchema <> ".chain_cursor LIMIT 1") []
      pure $ case rows of
        [Single s] -> Just s
        _ -> Nothing
    _ -> pure Nothing

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
runMigrations = do
  runMigration migrateAll
  -- A PLAIN index, deliberately not unique — see 'ProfileProjection'. Raw SQL because the
  -- @persistLowerCase@ quasi-quoter has syntax for unique constraints and none for a bare index,
  -- and the whole point of this one is that it is not a constraint.
  rawExecute
    "CREATE INDEX IF NOT EXISTS profile_projection_credential_idx \
    \ON profile_projection (profile_credential)"
    []

-- | Bump when the chain-sync DB schema changes incompatibly; startup wipes + re-syncs on a mismatch.
--
--   * v1: first schema of this registry (profile + attestation projections). Nothing was deployed, so
--     the inherited v4 history does not carry over.
--   * v2: @AttestationProjection@ gained @attestation_kind@, @claimed_period_from@ and
--     @claimed_period_to@. A re-sync is the point: the three columns are read off the datum, so rows
--     written before them cannot be backfilled from the database — only from the chain.
--   * v3: @DisputeProjection@ added, @ProfileProjection@ gained @profile_credential@, and
--     'Palmares.Ingestion.projectChainEvent' now authenticates a UTxO before projecting it
--     (inherited fix #3). The re-sync is not optional: the credential comes off the datum, and
--     every row already written was written WITHOUT the authentication check — so a v2 database may
--     hold planted rows that no replay of the raw match log would produce again.
--
-- @UnitTests.AttestSchema@ asserts this constant against the entity set, because a column added
-- without a bump is a deployed service migrating a new column onto rows that will never hold a value
-- for it, and nothing else in the test suite notices.
-- | Bumped to 4 by __ADR 0003__: @attestation_projection@ gained @attestation_credential@, and
-- @profile_projection.profile_credential@ stopped being read off the profile datum and became a
-- value derived from the attestation stream. Both changes mean an existing projection is wrong
-- rather than merely incomplete, so this bump is what forces the re-sync that rebuilds it.
currentSchemaVersion :: Int
currentSchemaVersion = 4

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
    "dispute_projection",
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
--
-- The raw match is stored unconditionally and the projection only if the output authenticates: the
-- match log is the replay source and must stay complete, while the projections are the state the
-- read API serves. 'Palmares.Ingestion.projectChainEvent' is where that line is drawn.
putMatchAndProjections :: (MonadIO m) => GYNetworkId -> GYMintingPolicyId -> KupoMatch -> SqlPersistT m ()
putMatchAndProjections networkId ourPolicy km = do
  putKupoMatch km
  projectAndStore networkId ourPolicy km

-- | Derive and store the projections for a raw match (does NOT re-store the raw match). Reused by
-- 'rollbackTo' to replay the surviving log. Conversion/projection failures are logged and skipped.
-- TODO(stream ?): dead-letter table for replayable failed projections.
projectAndStore :: (MonadIO m) => GYNetworkId -> GYMintingPolicyId -> KupoMatch -> SqlPersistT m ()
projectAndStore networkId ourPolicy km =
  case kupoMatchToAtlasMatch km of
    Left convErr -> liftIO $ putStrLn ("PROJECTION ERROR (dropped, raw match retained): conversion error: " <> convErr)
    Right am -> do
      let slotNoInt = slot_no (created_at km)
          header = header_hash (created_at km)
          txId = transaction_id km
          outIdx = output_index km
      ev <- runExceptT (projectChainEvent networkId ourPolicy am)
      case ev of
        Left e -> liftIO $ putStrLn ("PROJECTION ERROR (dropped, raw match retained): " <> show e)
        Right proj -> case proj of
          ProfileEvent p -> putProfileProjection slotNoInt header p
          AttestationEvent a -> putAttestationProjection slotNoInt header txId outIdx a
          DisputeEvent d -> putDisputeProjection slotNoInt header d
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
-- | Store a profile projection, upserting by profile id.
--
-- __The credential column is carried over, not written — ADR 0003.__ It is derived from the
-- attestation stream and this event does not carry it, while 'upsertByUnique' REPLACES the whole
-- row. Writing 'Nothing' here would therefore make every later metadata update silently erase a
-- binding a 'CredentialClaim' had established — a projection that drifts from the chain with no
-- error anywhere. Carrying the existing value is what keeps the derived column a function of the
-- attestations alone.
putProfileProjection :: (MonadIO m) => Integer -> Text -> Profile -> SqlPersistT m ()
putProfileProjection createdSlot createdHash p = do
  existing <- getBy (UniqueProfileProjection (profileId p))
  let credential = (profileProjectionProfileCredential . entityVal) =<< existing
  -- Named fields, not positional, for the reason 'putAttestationProjection' spells out: name,
  -- description and image URI are all 'Text', so a transposition among them compiles and writes a
  -- row with the description in the name column. Three same-typed neighbours is enough.
  let ev =
        ProfileProjection
          { profileProjectionCreatedAtSlot = createdSlot,
            profileProjectionCreatedAtHash = createdHash,
            profileProjectionProfileId = profileId p,
            profileProjectionProfileName = profileName p,
            profileProjectionProfileDescription = profileDescription p,
            profileProjectionProfileImageURI = profileImageURI p,
            profileProjectionProfileType = profileType p,
            profileProjectionProfileCredential = credential
          }
  upsertByUnique (UniqueProfileProjection . profileProjectionProfileId) ev

-- | Store a dispute projection, upserting by dispute ID.
putDisputeProjection :: (MonadIO m) => Integer -> Text -> ProjectedDispute -> SqlPersistT m ()
putDisputeProjection createdSlot createdHash d = do
  -- Named fields: dispute id, target and opener are all 'GYAssetClass'.
  let ev =
        DisputeProjection
          { disputeProjectionCreatedAtSlot = createdSlot,
            disputeProjectionCreatedAtHash = createdHash,
            disputeProjectionDisputeId = pdDisputeId d,
            disputeProjectionTargetAttestationId = pdTarget d,
            disputeProjectionOpenedByProfileId = pdOpenedBy d,
            disputeProjectionOpenedAt = pdOpenedAt d,
            disputeProjectionDeposit = pdDeposit d,
            disputeProjectionVerdict = pdVerdict d,
            disputeProjectionDisputeName = pdName d,
            disputeProjectionDisputeDescription = pdDescription d,
            disputeProjectionDisputeImageURI = pdImageURI d
          }
  upsertByUnique (UniqueDisputeProjection . disputeProjectionDisputeId) ev

-- | Store an attestation projection, upserting by attestation ID.
putAttestationProjection :: (MonadIO m) => Integer -> Text -> Text -> Int -> Attestation -> SqlPersistT m ()
putAttestationProjection createdSlot createdHash createdTxId createdOutIdx a = do
  -- Named fields, not positional. This was a 13-argument positional application and the claimed
  -- period took it to 16 — but the count is not the hazard: attestationId, subjectProfileId and
  -- issuerProfileId are all GYAssetClass, so a transposition among them COMPILES and writes a
  -- record attributing an attestation to the wrong profile. Names are what make that a type error
  -- again, and this is the one site that writes the row.
  let ev =
        AttestationProjection
          { attestationProjectionCreatedAtSlot = createdSlot,
            attestationProjectionCreatedAtHash = createdHash,
            attestationProjectionCreatedTxId = createdTxId,
            attestationProjectionCreatedOutputIndex = createdOutIdx,
            attestationProjectionAttestationId = attestationId a,
            attestationProjectionSubjectProfileId = attestationSubjectProfileId a,
            attestationProjectionIssuerProfileId = attestationIssuerProfileId a,
            attestationProjectionAttestationKind = attestationKind a,
            attestationProjectionAttestationCredential = attestationCredential a,
            attestationProjectionAttestationDate = attestationAttestationDate a,
            -- Two typed columns rather than one JSON blob, because the obvious read on a claimed
            -- period is a range ("who held this role in 2024?") and that is a plain WHERE on
            -- timestamps instead of a cast out of JSON. The "both or neither" invariant the domain
            -- type carries is held here by this being the only writer: `fst`/`snd` of one `Maybe`
            -- cannot disagree.
            attestationProjectionClaimedPeriodFrom = fst <$> attestationClaimedPeriod a,
            attestationProjectionClaimedPeriodTo = snd <$> attestationClaimedPeriod a,
            attestationProjectionIsAccepted = attestationAccepted a,
            attestationProjectionAttestationName = attestationName a,
            attestationProjectionAttestationDescription = attestationDescription a,
            attestationProjectionAttestationImageURI = attestationImageURI a,
            attestationProjectionOtherMetadata = Just $ AttestationOtherMetadataJson $ attestationOtherMetadata a
          }
  upsertByUnique (UniqueAttestationProjection . attestationProjectionAttestationId) ev
  -- __ADR 0003: this is where a profile's published credential comes from.__ The record above is the
  -- fact; the profile column is the derived current state, and replay order is what makes the
  -- derivation right — `sortedMatches` replays in true chain order, so a claim, a withdrawal and a
  -- later claim land in the order they were made and the last write is the current answer.
  case attestationKind a of
    CredentialClaim ->
      updateWhere
        [ProfileProjectionProfileId ==. attestationSubjectProfileId a]
        [ProfileProjectionProfileCredential =. attestationCredential a]
    -- A withdrawal clears the column only if it names the credential the profile currently
    -- publishes. Clearing unconditionally would let a withdrawal naming some OTHER credential
    -- delete a binding it has nothing to do with — the chain permits such a record (`Mc3` only asks
    -- the named credential to consent), so the read layer has to be the one that ignores it.
    CredentialWithdrawal -> do
      existing <- getBy (UniqueProfileProjection (attestationSubjectProfileId a))
      case existing of
        Just (Entity key row)
          | profileProjectionProfileCredential row == attestationCredential a ->
              update key [ProfileProjectionProfileCredential =. Nothing]
        _ -> pure ()
    _ -> pure ()

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
rollbackTo :: (MonadIO m) => GYNetworkId -> GYMintingPolicyId -> Integer -> SqlPersistT m ()
rollbackTo networkId ourPolicy slot = do
  -- 1. Discard raw matches strictly beyond the rollback slot (numeric compare; F-02 fixed).
  deleteWhere [OnchainMatchEventCreatedSlot >. slot]
  -- 2. Wipe all derived projection tables. Every table here must also be rebuilt by step 3, or the
  --    rollback is a deletion: a projection the replay cannot produce again is one this wipe loses.
  deleteWhere ([] :: [Filter ProfileProjection])
  deleteWhere ([] :: [Filter AttestationProjection])
  deleteWhere ([] :: [Filter DisputeProjection])
  -- 3. Replay surviving raw matches in true chain order.
  surviving <- selectList [] []
  mapM_ (projectAndStore networkId ourPolicy . onchainMatchEventKupoMatch) (replayOrder (map entityVal surviving))
