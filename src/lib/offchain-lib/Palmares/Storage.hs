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
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Persistent storage layer for chain-sync projections, cursor management, and rollback.
module Palmares.Storage where

import Control.Exception (SomeException, try)
import Control.Monad (foldM, forM_, unless, void)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Int (Int64)
import Data.List qualified as L
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Database.Persist
import Database.Persist.Sql
import Database.Persist.TH
import Palmares.DomainTypes.Core.Types
import GeniusYield.Types
import Palmares.Ingestion
import Palmares.ChainSync.KupoAtlas (kupoMatchToAtlasMatch)
import Palmares.ChainSync.KupoClient (CreatedAt (..), KupoMatch (..), SpentAt (..))

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

-- Singleton liveness row for the attestation projector — `CS-07`.
--
-- WHY IT IS NOT `ChainCursor`. The cursor is written only after a FULL pass over the window
-- (`attest-sync` calls `updateLocalTip` after `fetchingMatches` returns), so during a first sync —
-- or after any wipe — the projection tables fill for hours while the cursor still reads 0 or the
-- pre-wipe slot. `/ready` was green throughout and `/profiles` answered with confident, partial
-- pages. The cursor is a position; this row is a REPORT, written on every tick and again after
-- every window, so the gap between "I have applied up to here" and "the chain is here" is visible
-- while it is happening rather than afterwards.
--
-- `state` is the projector's own verdict and the field a probe reads: `syncing` while it is behind,
-- `following` once a pass has completed with the cursor at Kupo's tip, `rolled_back` on the tick a
-- fork was handled, `error` when a tick raised. A reader must not have to infer that from two slot
-- numbers, because the inference is exactly what was wrong before: equal slots can mean "caught up"
-- or "has never started".
--
-- `lastError` carries the text of whatever stopped the last tick, for the same reason
-- `AttestDeadLetter` does: the useful failures are the ones nobody predicted.
AttestSyncState
    singleton        Bool
    cursorSlot       Integer
    cursorHash       Text
    kupoTipSlot      Integer
    state            Text
    lastSyncAt       UTCTime
    policyHexText    Text
    schemaVersion    Int
    serviceVersion   Text
    lastError        Text Maybe
    UniqueAttestSyncState singleton
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

-- A match the projector could not apply, kept instead of lost — the second half of `CS-01`.
--
-- The first half put a guard at `onchainAttestationToAttestation`, the single boundary every datum
-- crosses, so the one unbounded datum value could no longer reach a `timestamptz`. This table is
-- about the shape of the failure rather than any one cause: a window used to be applied in ONE
-- transaction, so any single row Postgres refused aborted the batch, the cursor never advanced, and
-- the projector stopped for ever. Skipping the row silently would trade a halt for a hole; this
-- records what was skipped and why, so an operator can see it and re-drive it.
--
-- `lastError` is the exception's text and nothing structured on purpose: the useful failures are the
-- ones nobody predicted, and a constructor per predicted cause would not have had one for the
-- `POSIXTime 10^20` that started this.
AttestDeadLetter
    createdSlot        Integer
    createdHeader      Text
    createdTxId        Text
    createdOutputIndex Int
    kupoMatch          KupoMatch
    lastError          Text
    UniqueDeadLetter createdSlot createdHeader createdTxId createdOutputIndex
    deriving Show

-- Projection-specific flattened tables (domain fields + created_at).
-- Inherited fix #5: @createdAtSlot@ is the ONLY time a projection row carries. A wall clock
-- stamped at ingest is re-stamped by every 'rollbackTo' + replay, which silently renumbers
-- anything ordered by it; the chain's slot is immune to replay. Readers convert with
-- 'Palmares.TxBuilding.Utils.slotToUTC'.
--
-- profileCredential is the CIP-129 rendering of the credential the profile currently publishes.
-- DERIVED, not read off a datum — ADR 0003 removed the datum field and made a binding its own
-- record; 'deriveProfileCredential' is the fold. It carries
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
    staleAfter           GYTime
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
-- 5: `attest_dead_letter` (CS-01 second half). A bump still wipes — see ADR 0007, which keeps a
-- POLICY change from wiping and deliberately leaves a SCHEMA change wiping, because these tables
-- would otherwise need an in-place ALTER Postgres rejects. Harmless here: the only deployment this
-- precedes is a fresh one, where `needWipe` is False because there is no probe to compare against.
--
-- 6: `dispute_projection.stale_after`. The dispute's own deadline was in the datum and published
-- nowhere, so a client could only compute `opened_at + the oracle's current timeout` — wrong for any
-- dispute opened before a retiming, because the datum's deadline is absolute. The column is NOT NULL
-- and existing rows have no value for it, which is precisely what this bump exists to handle.
--
-- __This bump is also the re-index that was needed anyway.__ The authentication gate that dropped
-- every attestation (`5ae17bf`) was fixed after the projector's cursor had already passed the block
-- holding the one attestation on chain, so the record was correct in the code and absent from the
-- database with nothing to trigger a re-read. A wipe re-indexes from the chain, which fixes both.
currentSchemaVersion = 6

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

-- | Replace the projector's liveness row — `CS-07`.
--
-- Upserted on the singleton key, so it is one row for ever and a tick that writes it twice costs
-- nothing. Called on every tick and after every fetch window; see 'AttestSyncState' for why the
-- cursor alone was not enough.
putAttestSyncState :: (MonadIO m) => AttestSyncState -> SqlPersistT m ()
putAttestSyncState = upsertByUnique (const (UniqueAttestSyncState True))

-- | The projector's liveness row, or 'Nothing' when this database has no attestation pipeline.
--
-- Catalog-guarded exactly as 'attestCursorSlot' is, and for the same reason: query-api runs against
-- databases where attest-sync has never run, and @information_schema.tables@ lists only what the
-- current role may see — so a missing @GRANT@ reads as absence rather than as an error. The caller
-- distinguishes "no pipeline here" from "the pipeline is behind"; collapsing them is the defect
-- `CS-07` describes.
--
-- __The @FROM@ is schema-qualified, and that is load-bearing__ — the same rule 'attestCursorSlot'
-- states. This was written as @getBy (UniqueAttestSyncState True)@, which persistent renders as an
-- unqualified @FROM "attest_sync_state"@; @palmares_attest@ is not on query-api's @search_path@, so
-- the guard above answered "the table is there" (it asks the catalog by schema) and the read then
-- raised @42P01 relation "attest_sync_state" does not exist@. The poller caught that, logged it and
-- kept its previous value, so @\/status.attestation@ and @attest_lag_seconds@ stayed @null@ for ever
-- against a projector that was following normally — and @null@ is the one answer that reads as "this
-- deployment has no projector". Measured on preprod 2026-10-24.
attestSyncStateRow :: (MonadIO m) => SqlPersistT m (Maybe AttestSyncState)
attestSyncStateRow = do
  tbl <-
    rawSql
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables \
      \WHERE table_name = 'attest_sync_state' AND table_schema = ?)"
      [toPersistValue attestSchema]
  case tbl of
    [Single True] -> do
      rows <- rawSql ("SELECT ?? FROM " <> attestSchema <> ".attest_sync_state LIMIT 1") []
      pure $ case rows of
        (Entity _ row : _) -> Just row
        _ -> Nothing
    _ -> pure Nothing

-- | Record a match the projector could not apply, with the error that stopped it.
--
-- Upserted on the same key the match event uses, so re-driving a window that still fails replaces
-- the row rather than growing the table once per tick.
putDeadLetter :: (MonadIO m) => KupoMatch -> Text -> SqlPersistT m ()
putDeadLetter km err =
  upsertByUnique
    (\d -> UniqueDeadLetter (attestDeadLetterCreatedSlot d) (attestDeadLetterCreatedHeader d) (attestDeadLetterCreatedTxId d) (attestDeadLetterCreatedOutputIndex d))
    ( AttestDeadLetter
        (slot_no (created_at km))
        (header_hash (created_at km))
        (transaction_id km)
        (output_index km)
        km
        err
    )

-- | Apply a window of matches, and do not let one row stop the projector — the second half of
-- @CS-01@.
--
-- __In the library and not in @attest-sync@__, where it used to live. It needs a pool, a policy, a
-- network id and this module, all of which are library-level — and the executable's modules are not
-- on the test suite's @hs-source-dirs@, so a policy about what happens when a write fails was in
-- the one place a test could not reach it. Moving it is the smaller change than widening those
-- source dirs, and it is also where it belongs: this is projection-path behaviour.
--
-- __What it used to be, and why it was a halt rather than a hiccup.__ One @runAttest@ around the
-- whole window. Any single row Postgres refused aborted the transaction, so NOTHING in the window
-- landed; the cursor is persisted only after a range completes, so it never advanced; and the loop
-- above retries only Kupo client errors, so it did not even retry. One hand-built attestation, for
-- about 1.3 ADA, stopped the read layer for ever. The first half of @CS-01@ removed the one value
-- that could do it; this removes the SHAPE that let any value do it.
--
-- __Fast path unchanged.__ The window is still applied in one transaction, because that is one
-- round trip for ten thousand rows and the failure it guards against is rare. Only when that
-- transaction aborts does this fall back to one transaction per match, which is the slow,
-- diagnostic path and is paid for exactly once per bad window.
--
-- __Per-match and not per-row-inside-the-transaction__, because a @catch@ inside an aborted
-- Postgres transaction has nothing left to save: the transaction is already dead and every later
-- statement in it fails too. Isolation has to be a transaction boundary.
--
-- __The bad row is recorded, not dropped.__ Skipping it silently would trade a halt for a hole in
-- the registry, which is the worse of the two for something whose product IS the record.
-- 'putDeadLetter' keeps the match and the error so an operator can see what was skipped and
-- re-drive it after a fix.
-- Returns THE NUMBER OF DEAD-LETTERED MATCHES, so the caller can report it. This returned `()`
-- whether it had dead-lettered none or five hundred, and nothing read `attest_dead_letter`, so a
-- window that silently dropped records still reported `syncing` with an empty `last_error` and the
-- read surface stayed permanently incomplete behind three green probes.
applyMatches :: GYNetworkId -> GYMintingPolicyId -> ConnectionPool -> [KupoMatch] -> IO Int
applyMatches _networkId _ourPolicy _pool [] = return 0
applyMatches networkId ourPolicy pool matches = do
  putStrLn ("-----------------------------------------> Applying matches: " <> show (length matches))
  batch <- try (runAttest pool (forM_ matches (putMatchAndProjections networkId ourPolicy)))
  case batch of
    Right () -> return 0
    Left (batchErr :: SomeException) -> do
      putStrLn
        ( "BATCH ABORTED ("
            <> show (length matches)
            <> " matches): "
            <> show batchErr
            <> " — retrying one at a time to isolate the bad row(s)."
        )
      bad <- foldM (isolate) (0 :: Int) matches
      putStrLn
        ( "Isolation done: "
            <> show (length matches - bad)
            <> " applied, "
            <> show bad
            <> " dead-lettered. The cursor advances either way."
        )
      return bad
  where
    isolate deadSoFar km = do
      one <- try (runAttest pool (putMatchAndProjections networkId ourPolicy km))
      case one of
        Right () -> return deadSoFar
        Left (e :: SomeException) -> do
          putStrLn ("DEAD-LETTERED " <> show (transaction_id km) <> "#" <> show (output_index km) <> ": " <> show e)
          -- Its own transaction: the one that just failed is unusable, and this write must land.
          recorded <- try (runAttest pool (putDeadLetter km (Text.pack (show e))))
          case recorded of
            Right () -> return ()
            Left (e2 :: SomeException) ->
              putStrLn ("COULD NOT EVEN DEAD-LETTER IT: " <> show e2 <> " — the raw match is still in Kupo.")
          return (deadSoFar + 1)

-- | Upsert the singleton config row with a POLICY HISTORY and the current schema version.
--
-- __The column holds a history, newest first, as of ADR 0007__ — comma-separated, same column, same
-- type, no migration. A pre-existing row holding a single policy id parses as a one-element history,
-- which is what lets this land without the schema bump that would have wiped the very rows the
-- stance exists to keep.
--
-- __Why a history at all.__ The minting policy's hash is a function of all three validator hashes
-- plus the oracle token, so fixing ANY validator produces a new policy and therefore a new
-- registry's worth of ids. Stance (a) of @OC-09@ says old records stay readable, and every
-- projection row already carries its policy — each id is stored as a 'GYAssetClass', which is
-- @policy.name@ — so the read layer unions deployments for free. What it cannot do for free is know
-- WHICH registries the database holds, and that is this column.
putStoredPolicyHistory :: (MonadIO m) => [Text] -> SqlPersistT m ()
putStoredPolicyHistory history =
  upsertByUnique
    (const (UniqueChainSyncConfig True))
    (ChainSyncConfig True (Text.intercalate "," history) currentSchemaVersion)

-- | The policies a stored config row names, newest first. Tolerant of the single-id form written
-- before ADR 0007 and of stray whitespace.
parsePolicyHistory :: Text -> [Text]
parsePolicyHistory = filter (not . Text.null) . map Text.strip . Text.splitOn ","

-- | Table names for all entities in this persist block (persistLowerCase).
-- When adding a new entity to this block, add its table name here so wipeChainSyncTablesRaw drops it.
chainSyncTableNames :: [Text]
chainSyncTableNames =
  [ "attest_dead_letter",
    "attest_sync_state",
    "attestation_projection",
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
-- 'rollbackTo' to replay the surviving log.
--
-- A CONVERSION failure is logged and skipped here, and that is deliberate: the raw match is already
-- stored, so the replay source stays complete and a conversion that starts working after a fix
-- picks it up. A failure Postgres raises is a different animal — it aborts the transaction, so it
-- cannot be caught here at all, and `applyMatches` is where it is isolated into
-- 'putDeadLetter'. The TODO that stood here asked for exactly that table.
projectAndStore :: (MonadIO m) => GYNetworkId -> GYMintingPolicyId -> KupoMatch -> SqlPersistT m ()
projectAndStore networkId ourPolicy km =
  case kupoMatchToAtlasMatch km of
    -- DEAD-LETTERED, not only logged. These two branches used to `putStrLn` and return, so a match
    -- the projector could not convert or project was dropped with no row anywhere: invisible to
    -- `attest_dead_letter`, which is the one place an operator looks, and reproduced identically by
    -- every `rollbackTo` replay. A stderr line in a container's log is not a record.
    Left convErr -> do
      liftIO $ putStrLn ("PROJECTION ERROR (dead-lettered, raw match retained): conversion error: " <> convErr)
      putDeadLetter km ("conversion error: " <> Text.pack convErr)
    Right am -> do
      let slotNoInt = slot_no (created_at km)
          header = header_hash (created_at km)
          txId = transaction_id km
          outIdx = output_index km
      ev <- runExceptT (projectChainEvent networkId ourPolicy am)
      case ev of
        Left e -> do
          liftIO $ putStrLn ("PROJECTION ERROR (dead-lettered, raw match retained): " <> show e)
          putDeadLetter km (Text.pack (show e))
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

-- | Store a profile projection, upserting by profile id.
--
-- __The credential column is recomputed, not carried over — ADR 0003.__ It is derived from the
-- attestation stream and this event does not carry it, while 'upsertByUnique' REPLACES the whole
-- row, so writing 'Nothing' here would make every later metadata update silently erase a binding a
-- 'CredentialClaim' had established. The first fix for that was to carry the existing column over,
-- and that was order-dependent in a way a replay breaks — see 'deriveProfileCredential'.
putProfileProjection :: (MonadIO m) => Integer -> Text -> Profile -> SqlPersistT m ()
putProfileProjection createdSlot createdHash p = do
  credential <- deriveProfileCredential (profileId p)
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
            disputeProjectionStaleAfter = pdStaleAfter d,
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
  -- fact; the profile column is the derived current state. Recomputed from the records rather than
  -- written incrementally, so that this write and 'putProfileProjection' cannot disagree and
  -- neither depends on arriving first.
  case attestationKind a of
    CredentialClaim -> refreshProfileCredential (attestationSubjectProfileId a)
    CredentialWithdrawal -> refreshProfileCredential (attestationSubjectProfileId a)
    _ -> pure ()
  where
    refreshProfileCredential subject = do
      credential <- deriveProfileCredential subject
      updateWhere
        [ProfileProjectionProfileId ==. subject]
        [ProfileProjectionProfileCredential =. credential]

-- | The credential a profile currently publishes, folded from its credential attestations.
--
-- __ADR 0003's derived column, and why it is a fold rather than two incremental writes.__ The first
-- version wrote the column from each arriving record — a claim set it, a matching withdrawal
-- cleared it — and had 'putProfileProjection' carry the existing value over. That is correct only
-- while the profile row exists before the claim arrives, which is true of live operation and
-- __false of every replay__: 'projectChainEvent' emits no event for a spent output, so a profile
-- that was updated after claiming is seen only at its latest UTxO's slot, which is ABOVE the
-- claim's. The claim's @updateWhere@ then matched no row, silently, and the profile came back from
-- the re-sync with no credential. @currentSchemaVersion@ 3 -> 4 forces exactly that re-sync, so the
-- bug would have shipped as the upgrade path. Found by an audit reconciliation, not by a test.
--
-- A fold over the records has no such order: whichever of the two rows is written second recomputes
-- from everything already stored.
--
-- __The withdrawal rule.__ A withdrawal clears the column only if it names the credential the
-- profile published at that point in the fold. Clearing unconditionally would let a withdrawal
-- naming some OTHER credential delete a binding it has nothing to do with — the chain permits such
-- a record (@Mc3@ asks only the named credential to consent), so the read layer has to be the one
-- that ignores it.
--
-- __The order is chain order as closely as the table can express it__: slot, then output index,
-- then transaction id. Two credential records for one profile in the SAME slot but different
-- transactions are ordered by transaction id, which is deterministic but not the ledger's order;
-- the complete history stays in @attestation_projection@ either way.
deriveProfileCredential :: (MonadIO m) => GYAssetClass -> SqlPersistT m (Maybe Text)
deriveProfileCredential subject = do
  rows <-
    selectList
      [ AttestationProjectionSubjectProfileId ==. subject,
        AttestationProjectionAttestationKind <-. [CredentialClaim, CredentialWithdrawal]
      ]
      [ Asc AttestationProjectionCreatedAtSlot,
        Asc AttestationProjectionCreatedOutputIndex,
        Asc AttestationProjectionCreatedTxId
      ]
  return (L.foldl' step Nothing (map entityVal rows))
  where
    step current row = case attestationProjectionAttestationKind row of
      CredentialClaim -> attestationProjectionAttestationCredential row
      CredentialWithdrawal
        | current == attestationProjectionAttestationCredential row -> Nothing
      _ -> current

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
  -- 2. UN-SPEND what the rollback just un-did. CS-04.
  --
  --    A raw row is a SNAPSHOT, taken when Kupo handed it over: a UTxO first seen after it was
  --    already spent carries `spent_at` for ever, and `projectChainEvent` emits nothing for a spent
  --    output. So rolling back below the spend deleted the output the spend CREATED and left the
  --    spent one unprojectable — the record vanished from the registry entirely, and forward sync
  --    never brought it back because it was created below the rollback slot and no window reaches
  --    it again. One orphaned accept could erase an attestation until somebody accepted it a
  --    second time.
  --
  --    The clear is written back to the row and not only applied to the replay, because the next
  --    rollback reads the row again, and because the forward sync's own overlap re-fetch will set
  --    it anew if the spend really is on the canonical chain.
  rows <- selectList [] []
  let unspend e =
        let km = onchainMatchEventKupoMatch e
         in case spent_at km of
              Just sp | spent_slot_no sp > slot -> Just e {onchainMatchEventKupoMatch = km {spent_at = Nothing}}
              _ -> Nothing
      cleared = [(key, e') | Entity key e <- rows, Just e' <- [unspend e]]
  mapM_ (\(key, e') -> update key [OnchainMatchEventKupoMatch =. onchainMatchEventKupoMatch e']) cleared
  unless (null cleared) $
    liftIO
      ( putStrLn
          ( "Rollback to slot " <> show slot <> ": cleared a spend above it on " <> show (length cleared) <> " raw match(es)"
          )
      )
  -- 3. Wipe all derived projection tables. Every table here must also be rebuilt by step 4, or the
  --    rollback is a deletion: a projection the replay cannot produce again is one this wipe loses.
  deleteWhere ([] :: [Filter ProfileProjection])
  deleteWhere ([] :: [Filter AttestationProjection])
  deleteWhere ([] :: [Filter DisputeProjection])
  -- 4. Replay surviving raw matches in true chain order.
  let surviving = [maybe e id (unspend e) | Entity _ e <- rows]
  mapM_ (projectAndStore networkId ourPolicy . onchainMatchEventKupoMatch) (replayOrder surviving)
