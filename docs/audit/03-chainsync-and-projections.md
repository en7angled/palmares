# Audit 03 — Chain-sync and projections (Kupo → attest-sync → `palmares_attest` → query-api)

- Repository: `mariusgeorgescu/palmares`, branch `main`, HEAD `4eb9117` (2026-10-22). Static review only — no
  build, no test run, no containers. External facts were checked against the Kupo v2.12.0 OpenAPI spec
  (`docs/api/v2.12.0.yaml` in the Kupo repo) and the Atlas sources at the tag pinned in `cabal.project:28`.
- Scope: `src/lib/chainsync-lib/**`, `src/exe/attest-sync/**`, `Palmares.Ingestion`, `Palmares.Storage`,
  `Palmares.Admin.ApplySql` (attest parts), `src/exe/query-api/Query/Attest.hs` + attestation routes,
  attestation DTOs, the five attest test modules, `compose.yaml`, `deploy/`, `sql/{000,040,050}*.sql`.
- Convention: prose in the code is treated as a hypothesis; every finding cites `path:line` evidence.
- Could not verify without a toolchain: that the tree compiles; runtime behaviour of persistent's
  migration under `SET LOCAL search_path` (pinned by `UnitTests.AttestSchema`, which I could not run);
  exact PostgreSQL error text for out-of-range timestamps (the range limit itself is documented).

## 1. Executive summary

The projection pipeline is small and mostly well reasoned: the raw-match log + wipe-and-replay design is
sound, state UTxOs are authenticated by their CIP-67 reference NFT before they become rows, the read side
is fully parameterised SQL with stable ordering, and the schema is pinned to `palmares_attest` on every
connection. The serious problems are at the edges the comments do not cover:

| ID | Sev | One line |
|---|---|---|
| CS-01 | Critical | A self-reported `attestationPeriod` outside PostgreSQL's `timestamptz` range aborts the batch, kills the process and crash-loops forever: anyone with a profile can stop the projector permanently. |
| CS-02 | High | Fork detection compares slots only; an ordinary 1–2 block fork is classified `Behind`, orphaned matches stay projected, canonical replacements are missed, and the unused `/checkpoints/{slot}` client is the fix. |
| CS-03 | High | `attest-sync` is not provisioned anywhere (no compose service, no manifests), its documented DSN is the superuser, and tables created by `postgres` are unreadable by `palmares_ro`. |
| CS-04 | Medium | `rollbackTo` replays `spent_at` snapshots as-is: a state UTxO spent in an orphaned block vanishes from the projections and is never re-fetched. |
| CS-05 | Medium | Any exception in the sync loop is uncaught (process exit), Kupo errors are discarded before logging, decode failures spin forever, and `/ready` stays green while Kupo is unreachable. |
| CS-06 | Medium | The schema-version/policy wipe has no guard: one wrong `DEPLOYED_VALIDATORS_CONFIG` drops the raw-match log and six tables silently. |
| CS-07 | Medium | Attestation freshness is on `/ready` but not on the wire; absence is silent; `/ready` is green during a full resync while the tables are empty. The smoke doc is half-stale on this. |

## 2. The pipeline as built (what the code actually does)

1. Boot (`src/exe/attest-sync/Main.hs:72-141`): env → 16-connection pool under `runStdoutLoggingT`
   (`:79`) → Atlas core config used **only** for `cfgNetworkId` (`:81-82`) → deployed-validators config →
   policy id (`:84-94`) → `ensureAttestSchema` → `readSchemaProbe` → wipe if `storedVersion < 3 ||
   storedPolicy /= policy` (`:101-108`) → `runMigrations` → store policy → cursor → probe server → loop.
2. Loop (`Main.hs:143-170`): Kupo tip = head of `GET /v1/checkpoints` (`ChainSyncLogic.hs:64-77`);
   `evaluateChainSyncState` (`:32-39`); `Behind` → `fetchingMatches` over windows of `FETCH_BATCH_SIZE`
   slots with `created_after/created_before` (inclusive per the Kupo spec, hence the one-slot overlap the
   comment at `:79-81` describes), `policy_id=<ours>`, `order=oldest_first`, both `spent`/`unspent`
   unset (so spent and unspent matches are returned), `resolve_hashes` on (`:94-108`); each window is
   applied in ONE transaction (`:121-127`); the cursor is written only after the whole range (`Main.hs:159`).
3. Projection (`Palmares/Storage.hs:354-378`): raw `KupoMatch` upserted unconditionally by
   `(slot, header, txId, outputIndex)` (`:380-395`); `kupoMatchToAtlasMatch` → `projectChainEvent`
   (`Palmares/Ingestion.hs:81-103`): spent → `NoEvent`; address must equal one of the three compiled
   validator addresses for `networkId` (`:83,91,97,105`); datum must parse AND the value must hold exactly
   one CIP-67 **reference** token of our policy named by the datum (`:109-111`,
   `TxBuilding/Utils.hs:96-103`). Three projections: `ProfileEvent`, `AttestationEvent`, `DisputeEvent`,
   each upserted by its NFT id (`Storage.hs:137,157,175`).
4. Rollback (`Storage.hs:485-496`): delete raw matches with `created_slot > s`, delete all three projection
   tables, replay every surviving raw match in `(slot, txIndex, outputIndex)` order.
5. Read (`query-api/Query/Attest.hs`): `rawSql "SELECT ?? FROM palmares_attest.<table> ..."` with bound
   parameters, closed sort specs, `LIMIT/OFFSET` from `normalizeLimitOffset` (ceiling 200, offset ≤ 10000).
   `Query/Projected.hs`, `Query/Pages.hs`, `Query/Aggregates.hs` exist on disk but are **not compiled**:
   `palmares.cabal:359,366,367` comment them out of `other-modules`. Both CLAUDE.md files still route
   "new attestation query endpoint" to `Query/Projected.hs` and describe it as esqueleto (`CLAUDE.md`
   file-reference table; `src/exe/CLAUDE.md` "Attestations (`Query/Projected.hs`)") — stale.
6. Freshness: query-api polls `palmares_attest.chain_cursor` (`Storage.hs:208-221`, `Query/Gov.hs:519-527`)
   and fails `/ready` when `dbsync_tip_slot − cursor_slot > PALMARES_READY_MAX_LAG_SECONDS`
   (`Gov.hs:349`); `Nothing` passes (`:339-342`).

## 3. Findings

### CS-01 — Critical — A hostile `attestationPeriod` halts the projector permanently
- **Location**: `src/lib/onchain-lib/Palmares/Onchain/Validators/MintingPolicy.hs:104-107,243` (no
  check on `claimedPeriod`); `src/lib/offchain-lib/Palmares/TxBuilding/Conversions.hs:221`;
  `src/lib/offchain-lib/Palmares/Storage.hs:64-66,150-151,460-461`;
  `src/exe/attest-sync/ChainSyncLogic.hs:116,121-127`; `src/exe/attest-sync/Main.hs:143,159`.
- **What the code does**: the datum's `attestationPeriod :: Maybe (POSIXTime, POSIXTime)` is converted
  with `timeFromPlutus` (Atlas: `secondsToNominalDiffTime (fromIntegral t / 1000)`, no bound) and
  written as two `timestamptz` columns (`PersistField GYTime` → `PersistUTCTime`). On chain only
  `attestationDate` is range-checked (`Mq`, `MintingPolicy.hs:243`); the period "carries NO check"
  (`:107`), by design (`Protocol/Types.hs:344-349`). Off chain only inversion is refused
  (`TxBuilding/Operations.hs:361-363,414-415`), which a self-built transaction bypasses.
- **Why it is a problem**: Actor: anyone able to mint a profile (permissionless, `MintProfile`). Steps:
  (1) mint a profile; (2) build `NewAttestation` with `claimedPeriod = Just (0, 10^20)` (ms; year ≈
  3.2×10⁹) or a negative bound; the policy accepts it; (3) submit. attest-sync projects even unaccepted
  attestations; PostgreSQL rejects the `timestamptz` (documented range −4713..294276 AD) → `SqlError` →
  the window's single transaction aborts → the exception escapes `applyMatches` (no `try` anywhere on the
  path) → `forever` ends → process exits. On restart the cursor is unchanged (written only after the whole
  range, `Main.hs:159`), the same window is re-fetched, same crash. The raw match was never committed,
  so there is nothing to patch in the database; recovery needs a code change. Cost to the attacker: two
  transactions and min-ADA. The dead-letter table that would contain this is a TODO (`Storage.hs:361`).
- **Evidence**: `MintingPolicy.hs:107` "`@claimedPeriod@ is self-reported and carries NO check`";
  `Conversions.hs:221` `gyClaimedPeriod = fmap (Data.Bifunctor.bimap timeFromPlutus timeFromPlutus) attestationPeriod`;
  `Storage.hs:65-66` `toPersistValue gt = PersistUTCTime $ posixSecondsToUTCTime (timeToPOSIX gt)`;
  `ChainSyncLogic.hs:125-127` `runAttest pool (forM_ matches (putMatchAndProjections networkId ourPolicy))`.
- **Fix**: (a) in `onchainAttestationToAttestation`/`projectChainEvent`, treat a period outside a sane
  window (e.g. 1970-01-01 .. 9999-12-31, `from <= to`) as `NoEvent` with a logged reason, or store the
  period as `bigint` milliseconds and convert on read; (b) isolate failures per match: run each
  `projectAndStore` under its own exception boundary (own transaction, or `SAVEPOINT`/`ROLLBACK TO` via
  `rawExecute`), record failures in a `projection_dead_letter` table (match key + error), and let the
  window commit; (c) audit the other datum-sourced columns the same way (`deposit :: Integer` →
  `PersistField Integer` calls `error` above `Int64`, `Storage.hs:48-52`; today bounded by the oracle's
  `opDisputeDeposit`, `MintingPolicy.hs:171,393-394`); (d) optionally add an on-chain sanity bound on the
  period in the next redeploy (two integer comparisons). Add a test with a 10^20 period. **Effort: M.**

### CS-02 — High — Fork detection is slot-only; short forks are invisible
- **Location**: `src/exe/attest-sync/ChainSyncLogic.hs:32-39`; `src/exe/attest-sync/Main.hs:146-170`;
  `src/lib/chainsync-lib/Palmares/ChainSync/KupoClient.hs:273-287` (unused client).
- **What the code does**: the stored cursor `(slot, header)` is compared with Kupo's tip. The header is
  consulted only when the slots are equal (`:35`); `localSlot < blockchainSlot` is `Behind` (`:36`) and
  fetches `created_after=localSlot`. `rollbackTo` runs only in `Ahead`/`UpToDateButDifferentBlockHash`.
- **Why it is a problem**: Actor: the network (or two parties racing conflicting `AcceptAttestation`/
  `ResolveDispute` transactions). Steps: tick N stores cursor `(S, H)` and the matches of block H,
  including a state UTxO U2. Block H is orphaned; Kupo rolls back and, before the next 10 s tick, has
  applied H′ at slot S′ > S. Tick N+1 sees `S < S′` → `Behind`: nothing deletes U2 from the raw log or
  the projections, so the registry keeps serving a state that is not on the canonical chain; and any
  replacement block whose slot is < S is outside every future window, so its matches are never fetched.
  The Kupo spec warns exactly this ("outputs may end up in another block than the one they were
  initially advertised in") and offers `GET /checkpoints/{slot}?strict` to check a point; the client for
  it exists and has zero callers.
- **Evidence**: `ChainSyncLogic.hs:35-36` `| localSlot == blockchainSlot && localHeader /= blockchainHeader = UpToDateButDifferentBlockHash` /
  `| localSlot < blockchainSlot = Behind (...)`; `KupoClient.hs:279-280` `kupoCheckpointBySlot ...` (no
  references outside the module).
- **Fix**: on every tick, before deciding `Behind`, call `/v1/checkpoints/{cursorSlot}?strict` and
  compare the header; on mismatch (or `null`), find the newest surviving point by walking the distinct
  `(created_slot, created_header)` pairs of the raw log backwards (each verified the same way, bounded
  by `ROLLBACK_MARGIN`), `rollbackTo` it and re-fetch from there. Keep the margin rollback as the fallback.
  Move `evaluateChainSyncState` into `chainsync-lib` so it can be unit-tested (today it lives in the
  executable and the test-suite cannot import it, `palmares.cabal:482`). **Effort: M.**

### CS-03 — High — Not deployable as documented; privileges are convention, not enforcement
- **Location**: `compose.yaml` (whole file; Kupo `:169-225` is in profile `write`, there is no
  `attest-sync` service); `README.md:84,117-118,146`; `.env.example:10,17-21`; `Dockerfile.attest-sync:55`;
  `sql/050_roles.sql:69-92,116-117`; `src/exe/attest-sync/Main.hs:55,76`.
- **What the code does**: README says compose "brings up node + db-sync + Postgres + the API" and lists
  `attest-sync` as one of four binaries; `scripts/build-images.sh:22` and `.github/workflows/images.yml:94`
  build its image; nothing runs it. The only DSN the docs give (`PG_CONN_STR`, "one pool") is
  `user=postgres` — a superuser. `050_roles.sql` defines `palmares_owner` (owns `palmares_attest`) and
  `palmares_ro`, and grants `palmares_ro` SELECT on `palmares_attest` only via `ALTER DEFAULT PRIVILEGES
  FOR ROLE palmares_owner` (`:91-92`) plus a one-time `GRANT ... ON ALL TABLES` (`:87`).
- **Why it is a problem**: (1) `docker compose --profile app` serves `/profiles` from a schema nothing
  fills: `runRead` turns the missing table into 503 `DbUnavailable` (`QueryAppMonad.hs:78-86`), and the
  smoke test's "projection never appears" branch is the only diagnostic. (2) "This service owns only
  `palmares_attest`" (`src/exe/CLAUDE.md`) is enforced by nothing: as `postgres` it can write db-sync's
  tables; `runAttest` pins `search_path` (`Storage.hs:240-243`) but does not limit rights. (3) Ownership
  trap: if attest-sync connects as `postgres` (the documented default) while query-api serves as
  `palmares_ro` (the documented two-role deployment), the six tables are owned by `postgres`, the
  default-privilege rule for `palmares_owner` does not apply, every attestation route returns 503 and the
  cursor probe logs "unreadable" and reports `Nothing` — which `/ready` treats as fine (CS-07).
- **Evidence**: `compose.yaml:263-283` (query-api service; no sibling for attest-sync);
  `Dockerfile.attest-sync:55` `PG_CONN_STR="host=postgres user=postgres password=postgres dbname=cexplorer port=5432"`;
  `050_roles.sql:91-92` `ALTER DEFAULT PRIVILEGES FOR ROLE palmares_owner IN SCHEMA palmares_attest GRANT SELECT ON TABLES TO palmares_ro;`.
- **Fix**: add an `attest-sync` compose service in a `attest` (or `write`) profile depending on `kupo`
  and `postgres`, with `PALMARES_ATTEST_PG_CONN_STR` defaulting to a `palmares_owner` DSN; document that
  attest-sync must connect as `palmares_owner` (and why); have attest-sync verify at boot that
  `current_user` is not a superuser and owns `palmares_attest` (`SELECT nspowner = current_user::regrole`)
  and refuse otherwise; extend `scripts/check_roles.sh` with "tables in `palmares_attest` are owned by
  `palmares_owner`". **Effort: S–M.**

### CS-04 — Medium — Replay treats a stale `spent_at` as truth; orphaned spends delete state
- **Location**: `src/lib/offchain-lib/Palmares/Storage.hs:485-496`; `src/lib/offchain-lib/Palmares/Ingestion.hs:82`.
- **What the code does**: `rollbackTo s` deletes raw matches with `created_slot > s` and replays the
  rest; `projectChainEvent` returns `NoEvent` for any match whose snapshot carries `spent_at` (`:82`),
  regardless of the spend's slot. The raw row is a snapshot taken when it was fetched: a UTxO fetched
  after it was spent has `spent_at` set forever (and the overlap slot re-fetch upserts the newer snapshot
  over the older, `Storage.hs:387-395`).
- **Why it is a problem**: Actor: the network. Steps: attestation U1 (slot 1000, unaccepted) is first
  fetched after its accept at slot 5000 (fresh deployment, or any post-wipe resync) → raw U1 has
  `spent_at = 5000`, raw U2 (accepted) at 5000. The accept block is orphaned and CS-02's detection (or the
  margin path) rolls back to 4000: U2 is deleted, U1 is replayed as `NoEvent`, the attestation has **no
  row**. Forward sync starts at 4000, U1 was created at 1000, so it is never fetched again; the record
  exists on chain (unaccepted) and is absent from the registry until someone accepts it. Same for a
  dispute whose resolution is orphaned and for a profile whose `UpdateProfile` is orphaned.
- **Evidence**: `Storage.hs:488` `deleteWhere [OnchainMatchEventCreatedSlot >. slot]`;
  `Ingestion.hs:82` `| isJust amSpentAt = return (NoEvent am)`; nothing touches `spent_at` on rollback.
- **Fix**: `rollbackTo` must pass the rollback slot into the replay and treat `spent_at.slot_no > s` as
  unspent (clear it in the stored snapshot too), or re-fetch the rolled-back range with `spent_after=s`
  to refresh snapshots. Add a Pg test: U1 fetched spent + U2, rollback below U2's slot, expect U1's row
  back with `is_accepted = false`. **Effort: S.**

### CS-05 — Medium — Loop robustness: crash on any exception, silent retries, green probe while stuck
- **Location**: `src/exe/attest-sync/ChainSyncLogic.hs:64-77,87-127`; `src/exe/attest-sync/Main.hs:143-170`;
  `src/exe/attest-sync/ChainsyncAPI.hs:57-63`; `src/lib/chainsync-lib/Palmares/ChainSync/KupoClient.hs:216-220`.
- **What the code does**: Kupo `ClientError`s are discarded (`Left _err`, `:68,110`) and retried every
  10 s on the same window with no backoff and no error text; any database exception (outage, CS-01,
  `error` in `PersistField Integer`) propagates out of `forever` and ends `main`. `getBlockchainTip`
  loops without updating `SyncMetrics`, so when Kupo is down the probe keeps the last state (`UpToDate`
  or `Behind False`) and `/ready` answers 200 (`ChainsyncAPI.hs:60-62`); `smLastSyncTime` is never read by
  the verdict; `smDbReady`/`smMigrationsComplete` are constant `True` (`Main.hs:129-130`). Each call builds
  a new TLS `Manager` (`KupoClient.hs:218`) with http-client's default timeouts; a body stall on the
  streamed `/matches` response is not bounded. A window decode failure (Kupo schema change) spins forever
  while `/ready` may stay green (lag < 1200 slots).
- **Why it is a problem**: Actor: operations. A transient Postgres restart kills the process; under a
  restart policy that is a reboot plus a full re-scan of the in-flight range; a Kupo upgrade that renames a
  field produces an unexplained "Kupo client error ... (retrying)" line every 10 s with no way to see why.
- **Evidence**: `ChainSyncLogic.hs:110-114` `Left _err -> do putStrLn "Kupo client error while fetching matches (retrying)" ... fetchingMatches ...`;
  `Main.hs:143` `forever $ do` with no handler; `ChainsyncAPI.hs:61-62` `UpToDate -> pure probeStatus; Behind False -> pure probeStatus`.
- **Fix**: wrap one loop iteration in `try`, log `displayException`, set a `smLastError`/`smKupoOk` field,
  back off exponentially (cap 5 min), and keep the process alive; log the `ClientError` (it is `Show`);
  make `/ready` depend on `now − smLastSyncTime < threshold` and on the last Kupo `/health` result
  (`kupoHealth` exists, unused); create one `Manager` at boot with explicit `responseTimeout`; persist the
  cursor per window (`updateLocalTip` after each successful `applyMatches`) so restarts resume. **Effort: M.**

### CS-06 — Medium — The wipe is unguarded and can destroy a healthy database
- **Location**: `src/exe/attest-sync/Main.hs:96-110`; `src/lib/offchain-lib/Palmares/Storage.hs:302-316,321-347`.
- **What the code does**: `needWipe = storedVersion < currentSchemaVersion || storedPolicy /= policyHexText`
  → `DROP TABLE ... CASCADE` on all six tables, including `onchain_match_event` and `chain_cursor`, after
  one `putStrLn`.
- **Why it is a problem**: Actor: an operator. Steps: point `DEPLOYED_VALIDATORS_CONFIG` at the wrong
  file (a stale copy, the example, another network's deployment) and restart; the policy differs; the
  service drops the raw-match log and resyncs from Kupo origin. With Kupo started from `KUPO_SINCE=<tip>`
  (the "fast path" `compose.yaml:196-202` recommends) the history before that point cannot be rebuilt at
  all. A downgrade (`storedVersion > current`) is not handled either (no wipe, in-place migration).
- **Evidence**: `Main.hs:103-108` `needWipe = ... storedPolicy /= policyHexText ... when needWipe $ do putStrLn "Schema version or policy changed; dropping chain-sync tables before migration." runAttest pool wipeChainSyncTablesRaw`.
- **Fix**: refuse to boot on a policy mismatch unless `ATTEST_SYNC_CONFIRM_WIPE=<stored policy hex>`
  matches, printing both ids; treat a version downgrade as fatal; prefer `TRUNCATE`+migrate over `DROP`
  for the version bump, and keep a copy of `chain_sync_config` history (who/when/why). **Effort: S.**

### CS-07 — Medium — Freshness: on the probe but not on the wire; absence is silent; docs half-stale
- **Location**: `src/exe/query-api/Query/Gov.hs:308-350,477-527,539-551`; `src/exe/query-api/Query/ServiceStatus.hs:58-78`;
  `src/lib/offchain-lib/Palmares/DomainTypes/Transfer/QueryResponses.hs:542-551`;
  `docs/deployment/attest-flow-smoke.md:138-142`; `scripts/smoke_attest_flow.sh:137,150,230,235`.
- **What the code does**: query-api computes `attestLag = dbsync_tip_slot − chain_cursor.slot_no`
  (slots read as seconds) and fails `/ready` above `PALMARES_READY_MAX_LAG_SECONDS`; `Nothing` (no
  table, no row, permission error) passes; `/status` carries only `governance`; the five freshness headers
  are governance-only. The cursor row is written only after a full pass (`Main.hs:159`), so during the
  first sync and after every wipe the tables fill for hours while `/ready` is green and `/profiles`
  returns confident, partial pages. The smoke doc says "Neither service reports attest-sync's lag" —
  true for `/status` and headers, false for `/ready` (`Gov.hs:349`), and its own comment admits the gap
  ("absence is currently SILENT", `Gov.hs:487`).
- **Evidence**: `Gov.hs:349` `| Just lag <- readyAttestLagSeconds, lag > maxLag = Just IndexerBehind`;
  `Gov.hs:522-523` `Right (Just cursor) -> atomically (writeTVar av (Just (fromIntegral (max 0 (tipSlot - cursor)))))`;
  `QueryResponses.hs:547` `statusGovernance :: SyncStatus` (no attestation block).
- **Fix** (concrete): (1) attest-sync writes a singleton `palmares_attest.sync_state` row on every tick and
  per window: `cursor_slot, cursor_hash, kupo_tip_slot, state, last_sync_at timestamptz, policy_id,
  schema_version, service_version, last_error`. (2) query-api's `pollAttest` reads it and publishes
  `attestation: {slot, lag_seconds, state, last_sync_at, is_ready, policy_id, source: "attest-sync/kupo"}`
  on `/status` and `X-Attest-Slot`, `X-Attest-Lag-Seconds`, `X-Attest-Policy` headers (bump Swagger,
  update `scripts/check_swagger.sh`). (3) `/ready` red on absence when `PALMARES_EXPECT_ATTEST=true`, and on
  `now − last_sync_at > max_lag` (catches a frozen process whose cursor never moves). (4) Fix the doc and
  the script's three comments. **Effort: M.**

### CS-08 — Medium — Kupo drift is undetectable: `--since`, `--match`, pruning, network
- **Location**: `compose.yaml:181-205`; `src/exe/attest-sync/Main.hs:137-141,143-159`;
  `src/lib/chainsync-lib/Palmares/ChainSync/KupoClient.hs:296-335` (health/metrics clients, unused).
- **What the code does**: at boot the service logs "Kupo: configured" and starts fetching; it never checks
  Kupo's `/health` (`kupo_network_synchronization`, connection status), never checks that Kupo's oldest
  checkpoint is ≤ the stored cursor, never checks that Kupo's `--match` covers the policy, and never
  checks that Kupo's network equals `cfgNetworkId`.
- **Why it is a problem**: Actor: an operator following `compose.yaml:196-202`. Kupo's volume is lost and
  restarted with `KUPO_SINCE=<recent tip>`; its tip passes the cursor within minutes → `Behind` → every
  match between the cursor and the new start point is silently never indexed. A narrowed `KUPO_MATCH`
  that omits the validator addresses yields an empty, "up to date" registry. A `networkId` mismatch makes
  every match `NoEvent` (addresses never equal, `Ingestion.hs:105`). Kupo's `--prune-utxo` (not set
  today, correctly) would make `?spent` empty after 36 h and change replay semantics.
- **Evidence**: `Main.hs:139` `putStrLn "Kupo: configured"`; `ChainSyncLogic.hs:94-108` (no health
  or range check before the first window).
- **Fix**: boot preflight: `GET /health` must say synchronised and connected; `GET /v1/checkpoints` tail
  (oldest sampled point) must be ≤ cursor slot or the service refuses to continue past it without
  `ATTEST_SYNC_ACCEPT_GAP`; decode the first match's address network tag and compare with `networkId`;
  document that `--prune-utxo` must stay off. **Effort: S.**

### CS-09 — Medium — Configured policy vs compiled validators can disagree silently
- **Location**: `src/exe/attest-sync/Main.hs:84-94`; `src/lib/offchain-lib/Palmares/Ingestion.hs:83-105`.
- **What the code does**: the policy id comes from `DEPLOYED_VALIDATORS_CONFIG`; the addresses a match must
  sit at come from the binary's compiled validators (`profilesValidatorHashGY` etc.). The minting policy is
  parameterised by those validator hashes plus the oracle token, so a deployed policy that does not
  belong to this binary's validators can never produce a projectable match.
- **Why it is a problem**: Actor: an operator deploying a newer image against an older deployment (or vice
  versa). Every output is `NoEvent`; the raw log fills; `/ready` is green; the registry is empty. No log
  line names the validator addresses being indexed.
- **Fix**: at boot recompute the expected policy from the compiled validator hashes + the configured oracle
  token (the same construction `admin deploy` uses) and die on mismatch; log the three validator
  addresses and the policy id. **Effort: S.**

### CS-10 — Medium — No single-writer guard; a second replica corrupts the cursor and upserts
- **Location**: `src/lib/offchain-lib/Palmares/Storage.hs:276-285,289-293`; `src/exe/attest-sync/Main.hs:143-170`.
- **What the code does**: `upsertByUnique` is `getBy` then `insert`/`replace` (not atomic); the cursor is
  a singleton row both replicas read and write; nothing takes a lock.
- **Why it is a problem**: Actor: an orchestrator scaling `attest-sync` to 2 (or a rolling update with
  overlap). Both replicas fetch overlapping windows; one hits a unique violation in `insert` → exception →
  crash (CS-05); the cursor flips between tips; a rollback in one replica wipes projections while the
  other is writing.
- **Fix**: `SELECT pg_try_advisory_lock(<constant>)` on a dedicated connection at boot; exit if not
  acquired; use `INSERT ... ON CONFLICT DO UPDATE` (persistent `upsertBy`/`repsertBy`) so the upsert is
  atomic. **Effort: S.**

### CS-11 — Low — The raw-match log stores every wallet UTxO that holds a user token
- **Location**: `src/exe/attest-sync/Main.hs:137`; `src/exe/attest-sync/ChainSyncLogic.hs:94-108`;
  `src/lib/offchain-lib/Palmares/Storage.hs:354-357,380-395,495-496`.
- **What the code does**: the pattern is `<policy>.*` (every asset name, including CIP-67 user tokens),
  the raw match is stored unconditionally with the wallet's full `value.assets` map, and `rollbackTo`
  replays the whole log.
- **Why it is a problem**: every transfer or consolidation of a wallet holding a profile user token adds a
  row; an adversary can add thousands per day for fees only; each rollback (CS-02 fix will make them
  more frequent) is O(all rows) in one transaction.
- **Fix**: store raw matches only for the three validator addresses (they are the only projectable
  ones), or query by address pattern instead of policy (three `/matches/<validator addr>` calls per
  window); keep `rollbackTo` replay bounded to rows above `s − margin` plus the latest row per NFT.
  **Effort: S–M.**

### CS-12 — Low — Documentation/config mismatches around attest-sync
- **Location**: `src/exe/attest-sync/Main.hs:112-114`; `README.md:151-152`; `.env.example:19-20`;
  `Dockerfile.attest-sync:56-57`; `src/lib/offchain-lib/Palmares/Constants.hs:33-35`; `CLAUDE.md`
  (file-reference table), `src/exe/CLAUDE.md` ("Query/Projected.hs", "Query/Metrics.hs");
  `src/exe/query-api/Query/Common.hs:161-169`.
- **What the code does / mismatch**: `FETCH_BATCH_SIZE` defaults to `10_000_000` in code vs `100000` in
  README, `.env.example` and the Dockerfile; `BATCH_SIZE` is documented in all three and read nowhere;
  `ROLLBACK_MARGIN` is in slots (`Constants.hs:33`) while 2160 is Cardano's `k` in blocks — fine as a
  margin, misleading as a number; CLAUDE.md routes attestation endpoints to the uncompiled
  `Query/Projected.hs` and calls it esqueleto (the live module is `Query/Attest.hs`, raw SQL);
  `src/exe/CLAUDE.md` names `Query/Metrics.hs`, which does not exist; `Common.hs:161-169` says the
  inherited handlers still call `legacyNormalizeLimitOffset` — only dead `Pages.hs` does.
- **Fix**: align defaults (pick 100 000), delete `BATCH_SIZE`, state the unit, update both CLAUDE.md
  files and the smoke doc (CS-07). **Effort: S.**

### CS-13 — Low — Read surface does not deliver what the on-chain comments demand
- **Location**: `src/lib/onchain-lib/Palmares/Onchain/Protocol/Types.hs:355-356,455-458`;
  `src/lib/onchain-lib/Palmares/Onchain/Validators/AttestationsValidator.hs:14-33`;
  `src/exe/query-api/Query/Attest.hs:302-319,383-410,426-437`; `src/exe/query-api/RestAPI.hs:894-903`;
  `src/lib/offchain-lib/Palmares/DomainTypes/Transfer/QueryResponses.hs:1749-1753,1784-1803`.
- **Gaps**: (1) "the read layer can say contested" — list rows (`AttestationRow`) carry no
  `open_disputes`/`contested` field; only `GET /attestations/{id}` inlines disputes, so a list needs N+1
  calls. (2) "presenting a lineage attestation as pending ... is the real defect and belongs to the read
  surface" (`AttestationsValidator.hs:30-33`) — nothing distinguishes a subject that is an attestation id
  from a profile id; such rows sort as "unaccepted" in the track record. (3) `claimed_period` is
  published beside `date`, not `issued_at` as `Types.hs:355-356` prescribes; harmless but the name is the
  contract. (4) `/search` always returns empty `profiles`/`attestations` groups "to be filled over the
  attestation schema later" (`RestAPI.hs:900-901`) although `/profiles?q=` exists. (5) The DTO comment
  "A claim is not a proof: nothing on chain checks that the claimant controls the credential"
  (`QueryResponses.hs:1751-1752`) contradicts `Mp3` (`MintingPolicy.hs:289,320-321`,
  `Onchain/Utils.hs:256-300`): control IS proven at mint time. The read layer should say "control proven
  at claim time; `total > 1` means the same controller claimed twice", not "unverified".
- **Fix**: add `open_disputes :: Int` and `subject_kind :: profile|attestation` (one `EXISTS`/join each)
  and an `acceptance :: accepted|pending|not_applicable` enum; rename `date` → `issued_at` at the next
  Swagger bump; fill the two search groups; correct the DTO comment and the smoke doc wording.
  **Effort: M.**

### CS-14 — Low — Provenance and time semantics of projection rows
- **Location**: `src/lib/offchain-lib/Palmares/Storage.hs:117-121,128-176,398-414,437-468`;
  `src/exe/query-api/Query/Attest.hs:211,406-409`; `src/lib/offchain-lib/Palmares/DomainTypes/Transfer/QueryResponses.hs:1740-1745`.
- **What the code does**: every projection is upserted by NFT id, so `created_at_slot`, `created_at_hash`,
  `created_tx_id`, `created_output_index` are those of the **latest** UTxO: after `AcceptAttestation` the
  attestation's `tx_hash` is the accept tx (the smoke script already asserts this flip,
  `scripts/smoke_attest_flow.sh:303,321`); after `UpdateProfile` a profile's `created_at_slot` moves, so
  `order_by=registered_at` (`Attest.hs:211`) is really "last updated". Profiles and disputes store no tx
  pointer at all. No row carries block time; the DTO publishes a raw slot because "query-api holds no
  slot config" — yet the same database has `public.block(slot_no, time)` from db-sync, which is exact
  and era-proof. `slotToUTC` (`TxBuilding/Utils.hs:107-108`) is used only by dead code and tests.
- **Fix**: keep `first_seen_slot/tx` (set on insert, preserved on replace) beside `last_seen_*`; add the
  tx pointer to profiles and disputes; in query-api resolve `created_at_time` with `SELECT time FROM
  public.block WHERE slot_no = ?` (indexed in db-sync) or a `LEFT JOIN`; document "latest UTxO"
  semantics in the DTO. **Effort: S–M.**

### CS-15 — Low — Missing indexes on the columns the read side filters and sorts on
- **Location**: `src/lib/offchain-lib/Palmares/Storage.hs:140-176,245-254`; `src/exe/query-api/Query/Attest.hs:292-333,443-457`.
- **What the code does**: only the three `Unique*` ids and `profile_credential` are indexed.
  `/attestations?subject=|issuer=|kind=|accepted=|date_from=`, `order_by=date`, `/disputes?target=` and
  `order_by=registered_at` all scan.
- **Fix**: add in `runMigrations`: `attestation_projection(subject_profile_id)`, `(issuer_profile_id)`,
  `(attestation_date)`, `(created_at_slot)`; `dispute_projection(target_attestation_id)`, `(opened_at)`;
  `profile_projection(created_at_slot)`. **Effort: S.**

### CS-16 — Low — Operational hygiene: logging, secrets in images, needless config
- **Location**: `src/exe/attest-sync/Main.hs:79,81-82,135`; `Dockerfile.attest-sync:22,51`; `.dockerignore`;
  `.gitignore:44`; `src/lib/chainsync-lib/Palmares/ChainSync/KupoClient.hs:216-220`.
- **What the code does**: the pool is created under `runStdoutLoggingT`, so persistent logs every SQL
  statement with its parameters at debug level — two statements per raw match, each carrying the full
  `KupoMatch` JSON (query-api deliberately chose `runNoLoggingT` for the same reason,
  `query-api/Main.hs:101-104`). The DSN is redacted correctly (`Main.hs:60-63`). `COPY ./config
  /app/config` copies a developer's gitignored `config/config_atlas.json` (provider credentials) into
  every locally built image; `.dockerignore` excludes `*.prv`/`*.skey` but not that file. attest-sync
  requires the full Atlas core config (with provider section) only to read `networkId`. The probe thread
  is `forkIO`'d unsupervised; a bind failure is invisible.
- **Fix**: `runNoLoggingT` (or a filtered logger) for the pool; add `config/config_atlas.json` to
  `.dockerignore`; replace `ATLAS_CORE_CONFIG` in attest-sync with `CARDANO_NETWORK`; link the probe
  thread (`async` + `link`). **Effort: S.**

### CS-17 — Low — Test gaps on exactly the paths above
- **Location**: `src/test/UnitTests/Projections.hs:241-266,333-335,347-400`; `src/test/UnitTests/ChainSyncReplay.hs:148-162`;
  `src/test/UnitTests/StorageRoundtrip.hs`; `src/test/UnitTests/AttestSchema.hs:128-159`; `palmares.cabal:482`.
- **What the tests pin**: Projections — authentication (dust, wrong token, foreign policy, two copies,
  spent → none), replay byte-identity, rollback below a slot, idempotence, planted UTxO retained in the
  raw log, two claimants coexist. ChainSyncReplay — `replayOrder`, Kupo asset parsing,
  `authenticateStateUTxO`, `slotToUTC` with a one-era config. StorageRoundtrip — raw upsert idempotence
  and numeric rollback on SQLite (projection half vacuous, as its own header says). AttestSchema —
  schema placement, `SET LOCAL` pin, table list, column-count tripwire, non-unique credential index,
  field mapping. AttestRead — every route's filters, ordering and pagination.
- **Gaps**: no fixture has `spent_at` set together with a later UTxO of the same NFT (accept/resolve
  ordering untested); no stale-`spent_at`-after-rollback case (CS-04); `evaluateChainSyncState` and the
  loop are untested and unimportable (CS-02); no hostile-datum case (CS-01: period 10^20, negative,
  `deposit` > Int64); no `readyVerdict` case with `readyAttestLagSeconds` (grep finds none under
  `src/test`); no boot-time wipe decision test (CS-06); the era-boundary time question is moot today
  because the live path never converts slots.
- **Fix**: move loop logic to `chainsync-lib`; add the five cases above as Pg tests next to
  `Projections.hs`. **Effort: M.**

### CS-18 — Info — Small correctness notes in the Kupo adapters
- `KupoAtlas.hs:55-64`: with `resolve_hashes` on, a resolved **hash** datum arrives as
  `(Just d, Just dh, Just "hash")` and falls to `GYOutDatumNone` instead of `GYOutDatumHash`; harmless
  today (all protocol datums are inline) but wrong in general.
- `KupoAtlas.hs:89`: `spent_at.input_index` may be `null` per the spec; `mapM (maybeToEither ...)` then
  fails the whole conversion and logs "PROJECTION ERROR" for a match that would be `NoEvent` anyway.
- `Storage.hs:93-94`: `ChainCursor.lastTxId/lastOutputIndex` are always `Nothing` (`ChainSyncLogic.hs:47`).
- `QueryResponses.hs:1815`: `disputeRowId :: Core.AttestationAC` — a dispute id typed as an attestation id.
- `Main.hs:164,169`: the post-rollback cursor stores an empty header hash; harmless, but it guarantees
  the next equal-slot comparison can never be `UpToDate`.

## 4. Reviewed and not an issue
- **Spent-vs-created handling in the steady state** (hypothesis 2): `AcceptAttestation` (`A1`,
  `AttestationsValidator.hs:97-133`) and `ResolveDispute` (`D2`, `DisputesValidator.hs:104-157`) re-lock
  the NFT at the same address, so the newer UTxO carries the full state; upsert-by-NFT-id plus
  `(slot, txIndex, outputIndex)` ordering (which matches Kupo's "within a slot, by `transaction_index`")
  yields the latest state. Only the orphan case (CS-04) and fork detection (CS-02) break it.
- **One row per attestation** (hypothesis 7): `UniqueAttestationProjection attestationId`
  (`Storage.hs:157`); the accept replaces, never duplicates. Verified by `Projections.hs:373-379`.
- **Forged datum without the NFT** (hypothesis 4): `NoEvent`, raw match kept (`Ingestion.hs:109-111`,
  `Projections.hs:304-305,382-387`). A forged datum WITH the reference NFT is impossible: `Mp5/Mk/Md5`
  lock the ref token at the validator and `P5/A1/D2` keep it there; `Cleanup` only sweeps unbacked datums
  (`Onchain/Utils.hs:404-408`). The `--prune-utxo`-off Kupo config keeps spent history, but even with
  pruning the *current* state would still be complete after a resync (every live state UTxO is unspent).
- **search_path pinning on every connection** (hypothesis 8): every DB access in the service goes through
  `runAttest` (`Storage.hs:240-243`, `SET LOCAL` inside `runSqlPool`'s transaction); the one exception,
  `ensureAttestSchema`, is schema-qualified (`Storage.hs:228`). `UnitTests.AttestSchema:100-107` pins
  that it does not leak between pooled connections.
- **query-api boot never touches `palmares_attest`**: `Query/Views.hs:37-48` applies five files;
  `sql/000_schema.sql:7-10` drops only `palmares`; `sql/040_grants.sql` grants only on `palmares`.
- **SQL injection on the read side** (hypothesis 12): every request value is bound (`Attest.hs:147-179`);
  spliced text is module constants and closed `SortSpec`s; `LIKE` patterns are escaped
  (`Query/Common.hs:120-126`). Pagination is bounded (`Common.hs:44-88`).
- **`/profiles/by-credential/`**: returns every claimant, oldest first, with `total`; CIP-105/hex are
  refused with 400 rather than silently matched (`Attest.hs:97-125`, `RestAPI.hs:1565-1577`). The
  "no winner" behaviour is deliberate and tested (`AttestRead.hs:364`).
- **Metadata size**: bounded on chain for mint, issue, dispute and update (`Mm/Mn`, `Mp4`, `Md7`, `P4`;
  CIP68.hs:97-190) and decoded leniently (`Conversions.hs:46-47`), so no datum can crash the decoder.
- **Policy-change resync** (hypothesis 1): a redeploy changes the policy, the stored id differs, the wipe
  is the correct outcome; the match pattern derives from the same hash the projector authenticates with.
- **Chain time in projections** (hypothesis 5): no hard-coded preprod constants exist on the live path;
  rows carry slots only. `mainnetSlotConfig`/`makeSlotConfig` in Atlas are multi-era, so `slotToUTC`
  would be era-safe if it were ever wired to a real config. The only slot-as-seconds assumption is the
  readiness lag (`Gov.hs:523`), valid for every post-Byron slot on both networks.

## 5. What is done well
- Authenticate-before-project, with the CIP-67 reference-prefix conjunct and a test for every clause.
- Raw-match log as the replay source, wipe-and-replay rollback, deterministic `replayOrder`, idempotent
  upserts; `Projections.hs` asserts byte-identical rebuilds and "something to lose" before each assertion.
- Chain-time discipline: no wall clock in rows (inherited fix #5), explicit about it in the DTOs.
- `runAttest` + `SET LOCAL` and the AttestSchema test that re-creates the exact failure it prevents.
- Schema-version tripwire that fails next to the constant it owes.
- Read side: one transaction per composite read, bound parameters, total functions for `ORDER BY`,
  stable tiebreakers, counts over the same predicate, empty `IN` list = no filter, 404 vs empty page
  reasoned per route, disputes inlined with a bound.
- Honest comments where the design stops (lineage attestations, silent absence of the projector) — the
  gaps are documented even where they are not closed.

## 6. Hypotheses from the brief — verdicts
| # | Hypothesis | Verdict |
|---|---|---|
| 1 | Pattern from policy; wallet user tokens match | Confirmed: `<policy>.*` + `policy_id` filter (`Main.hs:137`, `ChainSyncLogic.hs:97`); wallet UTxOs are stored raw, projected `NoEvent` (CS-11). Stable only until redeploy, then a correct wipe (CS-06 for the guard). |
| 2 | Spent/created handled; latest state once | Steady state correct (§4); not "exactly once" (unaccepted then accepted rows), orphan replay wrong (CS-04), forks undetected (CS-02). |
| 3 | Projections present/missing | Profile, Attestation, Dispute. Missing: user-token holder, oracle params, update history, lineage distinction, contested flag (CS-13). |
| 4 | Authenticate before projecting | Confirmed everywhere; forged dust ignored (§4). |
| 5 | Slot → time | Not derived on the live path at all; raw slots published; lag uses 1 slot = 1 s (§4, CS-14). Network id from `ATLAS_CORE_CONFIG` (CS-16). |
| 6 | Rollback correctness/cost | Trim correct for creations, wrong for spends (CS-04); O(all raw rows) per rollback (CS-11); Kupo restart/`--since` undetected (CS-08); fork detection itself is the main hole (CS-02). |
| 7 | Idempotence / two rows | One row per NFT (§4); non-atomic upsert under concurrency (CS-10). |
| 8 | Wipe trigger & search_path | Pin verified on every connection (§4); wipe unguarded (CS-06). |
| 9 | Privileges | Convention only; superuser DSN documented; ownership trap (CS-03). `Views.hs` never touches `palmares_attest` (§4). |
| 10 | Freshness | Half-stale doc; `/ready` uses it, wire does not; proposal in CS-07. |
| 11 | Loop robustness | CS-01 (poison match), CS-05 (exceptions, retries, timeouts), CS-12 (`BATCH_SIZE` dead, default mismatch). |
| 12 | Read side | Safe SQL and paging (§4); semantic gaps (CS-13). |
| 13 | Data model | Indexes (CS-15), provenance/time (CS-14), bounded metadata (§4). |
| 14 | Tests | CS-17. |

## 7. Open questions for the owner
1. Is `attest-sync` meant to run from `compose.yaml` (a profile) or only from an external manifest set not
   in this repo? Where is the production deployment that `images.yml` feeds?
2. Which role should `attest-sync` connect as — `palmares_owner` (owns the schema) or a third role? The
   roles file has no answer, and the ownership rule in CS-03 depends on it.
3. Was the Kupo "fast path" (`KUPO_SINCE=<tip>`) ever used on a database that already had a cursor? If so,
   there is a hole in that database's raw log today (CS-08).
4. Do you want the registry to show the `attestationPeriod` as published, or clamp it (CS-01 fix choice)?
   Clamping is a read-layer statement about a self-reported value; `NoEvent` hides the record entirely.
5. Is the attestation `tx_hash`/`slot` meant to be "latest state UTxO" (what the smoke script asserts) or
   "issuance" (what `Attestation.attestationTxHash`'s comment says, `Core/Types.hs:210-213`)?
6. Is `/search` supposed to include profiles before mainnet? `RestAPI.hs:900-901` says "later".
7. Should `ROLLBACK_MARGIN` stay in slots (2160 s ≈ 108 blocks) once CS-02 verifies headers? A verified
   ancestor makes the margin a fallback, and the number can then be documented as such.

## 8. Improvement backlog (ranked)
| Rank | ID | Severity | Effort | Action |
|---|---|---|---|---|
| 1 | CS-01 | Critical | M | Bound/clamp datum-sourced timestamps; isolate each match's projection with a dead-letter table; add the 10^20 period test. |
| 2 | CS-02 | High | M | Verify the cursor header via `/checkpoints/{slot}?strict` each tick; walk back to the common point; move `evaluateChainSyncState` to `chainsync-lib` with tests. |
| 3 | CS-03 | High | S–M | Add the compose service + `palmares_owner` DSN; boot-time owner/non-superuser assertion; `check_roles.sh` table-ownership check. |
| 4 | CS-04 | Medium | S | Treat `spent_at.slot > rollbackSlot` as unspent during replay (and clear it); Pg test. |
| 5 | CS-05 | Medium | M | `try` per iteration, exponential backoff, log `ClientError`, `/ready` on `smLastSyncTime` + Kupo health, one `Manager` with timeouts, cursor per window. |
| 6 | CS-07 | Medium | M | `palmares_attest.sync_state`; `/status.attestation`; `X-Attest-*` headers; red on absence when expected; fix smoke doc/script comments. |
| 7 | CS-06 | Medium | S | `ATTEST_SYNC_CONFIRM_WIPE=<old policy>` guard; downgrade fatal. |
| 8 | CS-08 | Medium | S | Kupo preflight: health, oldest checkpoint ≤ cursor, network tag, document pruning must stay off. |
| 9 | CS-09 | Medium | S | Recompute the policy from compiled validators + oracle token; die on mismatch; log addresses. |
| 10 | CS-10 | Medium | S | Advisory lock single-writer; atomic `ON CONFLICT` upserts. |
| 11 | CS-15 | Low | S | Indexes on subject/issuer/date/target/opened_at/created_at_slot. |
| 12 | CS-11 | Low | S–M | Store raw matches for validator addresses only (or query by address); bound replay. |
| 13 | CS-13 | Low | M | `open_disputes`, `subject_kind`, `acceptance`, fill `/search` groups, fix the credential comment. |
| 14 | CS-14 | Low | S–M | `first_seen_*` columns, tx pointers on profiles/disputes, block time via `public.block`. |
| 15 | CS-12 | Low | S | Align `FETCH_BATCH_SIZE`, delete `BATCH_SIZE`, fix both CLAUDE.md and the unit of the margin. |
| 16 | CS-16 | Low | S | `runNoLoggingT`, `.dockerignore` the Atlas config, `CARDANO_NETWORK` instead of the core config, link the probe thread. |
| 17 | CS-17 | Low | M | The five missing test cases. |
| 18 | CS-18 | Info | S | Hash-datum classification, nullable `input_index`, dead cursor columns, dispute id type. |
