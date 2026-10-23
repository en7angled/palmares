# 06 — Documentation-vs-code consistency and product-gap review

> **Reconciled 2026-10-23 against `main` @ `2bf5bde`.** Every finding below has been re-judged; the per-finding verdicts, with current `path:line`, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md). Line references in this file are as of `4eb9117` and several have moved.

| | |
|---|---|
| Repository | `mariusgeorgescu/palmares`, branch `main`, HEAD `4eb9117` (2026-10-22) |
| Method | Static reading only (no build, no test run, no containers). Every claim below was checked by grep/read against the working tree and `git log` (read-only). |
| IDs | `DC-nn` = the written word disagrees with the code. `PG-nn` = the product promises something the repo does not deliver. `RL-n` = read-layer obligations delegated by on-chain comments. |
| Severity (docs) | **High** = a reader following the document will do the wrong thing, or is misled about a security/trust property. **Medium** = wrong but recoverable with a grep. **Low** = stale naming, drift, hygiene. |

## 0. Executive summary

The repository's prose is unusually rich — commit bodies, Haddocks and SQL headers explain *why* — but it was written over three days of fast rework and large parts of the **top-level documents still describe the Belt System ancestor or a plan that was later changed**. The five findings that matter most:

1. **DC-01 (High).** README §1 and the *generated* `docs/metrics.md` promise that the SQL published at `/metrics/formulas` *is* the SQL that produces every served number ("`Query.Metrics` looks each statement up … and runs it, so there is no second copy"). There is no `Query.Metrics`. Served DRep metrics come from the `palmares.drep_metrics` materialized view, which `sql/030_metrics.sql:28-32` itself calls "a second implementation of the same arithmetic", kept equal only by a manual check against preprod (`sql/checks/070_drep_metrics.sql`, not in CI).
2. **DC-43 (High).** The on-chain code cites "the spec" (§2, §3 glossary, §4.1, §4.3, §6) in at least nine places and the generated metrics doc links every formula to `docs/superpowers/design/f1-metric-formulas.md#…`. **None of these documents is in the repository**, so the protocol's requirements and the metric definitions are not reviewable from the code alone.
3. **DC-17/DC-18 (High).** `src/exe/CLAUDE.md` says `QueryAppContext` carries auth + a chain provider + one pool and that the public read surface is "rate-limited". The real context has no auth, no provider, and `Main.hs` opens a second pool; **no rate limiting exists anywhere** (`Envelope.hs:114`, `RestAPI.hs:9-10` delegate it to a "BFF" the repo does not ship).
4. **DC-40 / PG-02 (High).** The documented stack cannot run the attestation flow: `compose.yaml` has **no `attest-sync` service** (nothing populates `palmares_attest`), and its `write` profile omits `BASIC_USER`/`BASIC_PASS`, which `interaction-api` dies without (`Auth.hs:54-63`). Its comment also claims `operation.prv` is bind-mounted; no such mount exists.
5. **DC-02/DC-29 (High).** README §2 and ADR 0002 describe a Maestro token "supplied from the environment" as the only secret of the write path; `compose.yaml:240-243` actually runs the local-node + Kupo provider (no token), the token lives in a JSON config, write routes additionally require a shared HTTP Basic credential, and `attest-sync` — part of the *read* path — also needs the Atlas core config.

Counts: 43 DC items (11 High, 15 Medium, 17 Low), 16 product gaps, 6 read-layer obligations (3 PASS, 2 PARTIAL, 1 FAIL).

---

## 1. Claim-by-claim check

### 1.1 README.md

| ID | Sev | Claim (README) | Reality | Fix |
|---|---|---|---|---|
| DC-01 | High | §1 `README.md:21-23`: "Every metric ships with the exact SQL that computes it, served at `/metrics/formulas` … `docs/metrics.md` is generated from that catalog, so the documentation cannot drift from the code." `docs/metrics.md:10-12`: "the SQL below is the SQL that produces it: `Query.Metrics` looks each statement up by `formula_id` and runs it, so there is no second copy of the arithmetic". | No module `Query.Metrics` exists (`find src -name '*.hs'`). `/metrics/formulas` returns the embedded files (`RestAPI.hs:254`), but the numbers on `/dreps` and `/drep/{id}` are read from `palmares.drep_metrics` (`sql/030_metrics.sql:40`, refreshed by `Query/Refresh.hs:92`). That file says at `:28-32`: "EVERY NUMBER HERE MUST AGREE WITH resources/metrics/*.sql … This view is a second implementation of the same arithmetic … `sql/checks/070_drep_metrics.sql` exists to assert the two agree." That check runs only by hand against a caught-up preprod (`sql/checks/070_drep_metrics.sql:1-4`); CI's determinism job runs the formula files, not the matview parity. | Either (a) change the wording in the generator `src/lib/offchain-lib/Palmares/Metrics/Doc.hs:38`, `Metrics/Catalog.hs:11` and README §1 to: "served DRep metrics come from `palmares.drep_metrics`, a batched implementation of the published formulas; the two are asserted equal by `sql/checks/070_drep_metrics.sql` against preprod", or (b) build the matview from the embedded formula files so there is literally one copy. (a) is a one-commit fix; regenerate `docs/metrics.md` after it or CI fails. |
| DC-02 | High | §2 `README.md:31-33`: "The write path needs one key of your own. Submitting an attestation transaction is built through a chain provider; you supply your own token. We never hold your keys — transactions are built unsigned and signed in your wallet (CIP-30 / CIP-95)." | (1) Every write route sits behind `BasicAuth "user-realm"` (`src/exe/interaction-api/RestAPI.hs:246-256`); a wallet user cannot submit without the operator's shared `BASIC_USER`/`BASIC_PASS`. (2) The shipped stack does not use a token: `compose.yaml:240-243` configures `socketPath` + `kupoUrl` (local node provider). (3) Where a token *is* used it is inside the core-config JSON, not "the environment" (`README.md:158-159` says so itself; `config/config_atlas.example.json:3`). (4) No wallet/CIP-30 client code exists in the repo; the only signer is `admin sign-tx` (see PG-06). | Rewrite §2 to: "The write path is self-hostable too (node + Kupo, `--profile write`); a hosted provider token is optional. Write routes are protected by HTTP Basic auth that the operator issues; transactions are returned unsigned for a CIP-30/CIP-95 wallet (or `admin sign-tx`) to sign." |
| DC-03 | High | §11 `README.md:143-144`: `BASIC_USER`/`BASIC_PASS` "required, fail-closed — interaction-api, **admin**". `.env.example:4` same. | Only `Palmares.WebAPI.Auth.getBasicAuthFromEnv` reads them (`Auth.hs:56-57`) and only `interaction-api/Main.hs:64` calls it. `src/exe/admin/Main.hs` never reads `BASIC_*` (its env reads: `PALMARES_ADMIN_CONN_STR:863`, `PALMARES_OWNER_PASSWORD`/`PALMARES_RO_PASSWORD:694-695`). | Column "Used by" → `interaction-api` only. Same edit in `.env.example:4`. |
| DC-04 | High | §11 `README.md:146`: `PG_CONN_STR` "required — db-sync's own database". §11 preamble: "`fail-closed` means the service exits rather than starting with an unsafe default." | Both readers fall back to a hard-coded DSN **with a password**: `src/exe/query-api/Main.hs:31-32` (`host=postgres user=postgres password=postgres …`) and `src/exe/attest-sync/Main.hs:55` (`host=localhost …`). Unset → the service starts against a guessed database. That is fail-open. | Preferred: `die` when `PG_CONN_STR` is unset in both `Main.hs` files (one line each). Otherwise mark the row "optional, insecure default". |
| DC-05 | High | §11 `README.md:147-148`: `ATLAS_CORE_CONFIG` and `DEPLOYED_VALIDATORS_CONFIG` "required for the write path — interaction-api, admin". §2: the read path "needs no account, no API key". | `attest-sync` — the only writer of `palmares_attest`, i.e. the *read* path for attestations — `die`s without **both** (`src/exe/attest-sync/Main.hs:81,84`); it uses only `cfgNetworkId` and the minting-policy hash. So the attestation read surface needs a full Atlas core config (with a local node provider it needs no token, but the JSON must parse as a `GYCoreConfig`). | Add `attest-sync` to both rows and a footnote: "attest-sync reads only `networkId` and the policy hash". Longer term: give attest-sync `PALMARES_NETWORK` + `PALMARES_MINTING_POLICY_ID` so the read path never parses a provider config. |
| DC-06 | Medium | §11 `README.md:150-153`: `BATCH_SIZE` default `1000000`; `FETCH_BATCH_SIZE` default `100000`; `CORS_ALLOWED_ORIGINS` "required … both APIs". | `BATCH_SIZE` is read nowhere (`grep -rn lookupEnv src` lists only `FETCH_BATCH_SIZE`, `ROLLBACK_MARGIN`, `KUPO_URL`, `PG_CONN_STR` in attest-sync). `FETCH_BATCH_SIZE` defaults to `10_000_000` (`attest-sync/Main.hs:114`), not 100000. `CORS_ALLOWED_ORIGINS` is not required (unset = empty allowlist, `CORS.hs:36-43`) and is read by **three** services (`attest-sync/Main.hs:73`). `ROLLBACK_MARGIN` 2160 ✓ (`Constants.hs:35`); `PORT` defaults ✓; `KUPO_URL` ✓; `PALMARES_VIEW_REFRESH_SECONDS` 300 ✓ (`Refresh.hs:106`); `PALMARES_READY_MAX_LAG_SECONDS` 300 / `PALMARES_AMBER_LAG_SECONDS` 120 ✓ (`Gov.hs:354,362`). | Delete `BATCH_SIZE` (README and `.env.example:19`); fix `FETCH_BATCH_SIZE` default; CORS row → "optional; unset or empty = deny all cross-origin — query-api, interaction-api, attest-sync probe". |
| DC-07 | Medium | §11 `README.md:138`: "Every name below is read from the environment". | Names the code reads that the table omits: `PALMARES_PG_OWNER_CONN_STR` (`query-api/Main.hs:100`, documented only in `.env.example:15`), `PALMARES_NETWORK_NAME` (`Gov.hs:382`, default `preprod`, drives `/ready`), `PALMARES_FRESHNESS_POLL_MS` (`Gov.hs:374`), `PALMARES_ADMIN_CONN_STR`, `PALMARES_OWNER_PASSWORD`, `PALMARES_RO_PASSWORD` (`admin/Main.hs:863,694-695`), `PALMARES_API`, `KOIOS_API`, `KOIOS_API_TOKEN` (`admin/Reconcile.hs:91-93,403`), `PALMARES_TEST_PG_CONN_STR` (`Test/Pg.hs:48`), `PALMARES_FIXTURE_PG_CONN_STR` (`UnitTests/MetricFixture.hs:241`). | Add rows (service, default, fail-closed?). Add `PALMARES_NETWORK_NAME` in particular: a wrong default silently makes `/ready` red on a non-preprod deployment. |
| DC-08 | Medium | §10 `README.md:104-110`: `direnv allow` → `cabal update` → `cabal build all` → `cabal test`. `src/test/CLAUDE.md:46-48`: the skeleton fixture lets "the Haskell suite run with no database". | `cabal test` needs a running PostgreSQL and `PALMARES_TEST_PG_CONN_STR`, or `Test.Pg` `die`s (`src/test/Test/Pg.hs:11-14,48-53`); CI provisions `postgres:17-alpine` (`.github/workflows/ci.yml:15-26,116`). The skeleton is applied *into* a real Postgres per test. | README §10: add `export PALMARES_TEST_PG_CONN_STR="host=localhost user=postgres password=devonly dbname=postgres port=5432"` and a `docker run postgres:17-alpine` line. `src/test/CLAUDE.md:46-48` → "so the suite needs only an empty PostgreSQL, not a synced db-sync". |
| DC-09 | Medium | §6 `README.md:70`: `docs/generated/` — "generated Swagger and CIP-57 blueprint — committed, never hand-edited". | `docs/generated/` holds `.gitkeep` and `swagger/` only. `Constants.defaultBlueprintFile = "docs/generated/palmares-blueprint.json"` (`Constants.hs:27`) does not exist; no workflow runs `write-blueprint`; `admin/Main.hs:668-675` records exactly this ("THERE IS NO SUCH CHECK AND NO COMMITTED DOCUMENT"). | Commit the blueprint and add a CI step mirroring the Swagger gate (`cabal run -v0 exe:admin -- write-blueprint && git diff --exit-code docs/generated/`), or change the README row to "generated Swagger (committed, CI-gated); the blueprint is generated on demand and not yet committed". |
| DC-10 | Medium | §5 `README.md:53`: `attestation validators ──▶ Kupo ──▶ palmares_attest.* ──▶ query-api`. §8: "`compose.yaml` brings up node + db-sync + Postgres + the API." | The diagram omits `attest-sync` (the only process that writes `palmares_attest`, `Storage.hs:177-189`) and `interaction-api`. `compose.yaml` defines `cardano-node, postgres, cardano-db-sync, kupo, interaction-api, query-api` — **no `attest-sync`** (grep `^  [a-z-]+:$`). See PG-02. | Add attest-sync (and interaction-api) to the diagram; add an `attest-sync` service to the `write` profile. |
| DC-11 | Medium | §10 `README.md:133-134`: "`deploy/dbsync/db-sync-config.yaml` is the single source … the Kubernetes ConfigMap is generated from it, never forked." `compose.yaml:22-23`: "generated … by one `sed`". | No manifests, kustomization, Helm chart or generator script exist (`deploy/` has only `dbsync/` and `node-config/`). `scripts/measure_substrate.sh:21-22` and `scripts/check_roles.sh:21` hard-code `kubectl --context minirack-lan -n cardano-preprod … deployment-palmares-postgres`; `experiments/dbsync-preprod/README.md:6` points at an external `apps-k8s-configs/…` repository. | Say so: "cluster manifests live in `<repo>`; the ConfigMap is produced by `<command>`". Add the `sed` one-liner to `docs/runbooks/`. |
| DC-12 | Low | §6 layout table; "`src/test/` unit, property and emulator tests"; "`experiments/` … deleted once their numbers land in an ADR". | Table omits `test/` (fixtures, `dbsync-skeleton.sql`, Koios snapshots), `scripts/`, `deploy/`, `config/`, `sql/checks`, `sql/indexes`, `licenses/`. "Property tests" are exhaustive tables, not generators (`src/test/PropertyTests.hs:25-31`: "the plan asked for hedgehog. Neither arrived"); no privnet use (`mkPrivnetTestFor`/`withPrivnet` appear only in `src/test/CLAUDE.md`). `experiments/` is deliberately retained (`experiments/dbsync-preprod/README.md:131-143`). | Extend the table; say "unit, table-driven and CLB-emulator tests"; §6 experiments row → "retained until the top-level stack has its own synced database". |

### 1.2 Root `CLAUDE.md`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-13 | Medium | File reference `CLAUDE.md:56`: catalog in `query-api/Metrics/Catalog.hs`; `:58`: "aggregates in `Query/Aggregates.hs`, pages in `Query/Pages.hs`"; `:59`: attestation endpoints in `Query/Projected.hs`. `src/exe/CLAUDE.md:55`: "`Query/Metrics.hs` + `Metrics/Catalog.hs`". | The catalog is `src/lib/offchain-lib/Palmares/Metrics/Catalog.hs` (`palmares.cabal:229`). `Query/Metrics.hs` does not exist. `Query/Aggregates.hs`, `Query/Pages.hs`, `Query/Projected.hs` exist on disk but are comment-prefixed out of the build (`palmares.cabal:357-367`) and `scripts/check_vocabulary.sh:27-30` records that `Projected.hs` no longer compiles against the live DTOs. The live attestation module is `Query/Attest.hs` (`palmares.cabal:360`); `/pages/*` handlers live in `RestAPI.hs:1703-1704`. | Point the rows at `offchain-lib/Palmares/Metrics/Catalog.hs`, `query-api/Query/Attest.hs`, `RestAPI.hs`; either delete the three dormant modules or label them "dormant, not compiled". |
| DC-14 | Low | `CLAUDE.md:49` "New on-chain type → … `Onchain/Protocol/Id.hs`"; `src/lib/offchain-lib/CLAUDE.md:78` "ID derivation (`Id.hs`)". | `src/lib/onchain-lib/CLAUDE.md:24-26` says the opposite and is right: `deriveSeededId`/`deriveIndexedId` have no caller outside `Id.hs` (module only re-exported by `Protocol.hs:6,11`); real derivation is `Utils.nameFromTxOutRef` + `CIP68.generateRefAndUserTN` (29 references each). | Remove `Id.hs` from both checklists, or delete the module. |
| DC-15 | Low | `CLAUDE.md:82` "Swagger: Auto-generated on API startup"; `src/exe/CLAUDE.md:20,81` "Startup: Write Swagger JSON → …", "Written to `docs/generated/swagger/` on startup". | Both servers write Swagger **only** with `--write-swagger-only` and exit (`query-api/Main.hs:39-55,71-74`; `interaction-api/Main.hs:24-54`); a normal boot writes nothing. | "Generated by `cabal run exe:<svc> -- --write-swagger-only`; CI diffs the committed file (`ci.yml:165-170`)." |
| DC-16 | Low | `CLAUDE.md:50` "New validator" row. | Omits `Onchain/Blueprint.hs` (`Blueprint.hs:50-55` enumerates validators for CIP-57), `src/exe/admin/Main.hs` (`deploy-reference-scripts`), the regenerated `config/config_palmares_validators.json`, `compose.yaml` `KUPO_MATCH` note (`compose.yaml:185-194`), and `Storage.hs`/`Ingestion.hs` if the validator holds projected state. | Extend the row. |

### 1.3 `src/exe/CLAUDE.md`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-17 | High | `:42-43` "`QueryAppContext` = auth + `ProviderCtx` + **one** PostgreSQL `ConnectionPool` … There is no second pool." `:20` "Startup: Write Swagger JSON → load config → `withCfgProviders` → …" (for both servers). | `QueryAppContext` (`src/exe/query-api/QueryAppMonad.hs:30-48`) = `pgPool, freshness, attestLag, expectedNetwork, readyMaxLag, amberLag` — no auth, no provider (`:7-15`: "There is **no Cardano provider** … There is also **no auth context**"). `query-api/Main.hs:100-107` opens a **second** pool (`ownerPool`, `PALMARES_PG_OWNER_CONN_STR`) for DDL and refresh. `palmares.cabal:378-380`: no `atlas-cardano` in query-api. | Rewrite the "Query API Specifics" block from `QueryAppMonad.hs`'s own Haddock: two pools (serve / owner), no provider, no auth, freshness + attestation-lag TVars. |
| DC-18 | High | `:77-78` "**query-api's read surface is public** (rate-limited, no Basic auth)". | No rate limiting exists in any service, middleware, compose or workflow (`grep -rni 'rate.?limit'`): `Envelope.hs:113-115` declares `rate_limited` "unreachable in Plan A"; `RestAPI.hs:9-10` and `QueryAppMonad.hs:14` say it "belongs to the BFF in front of it" — and no BFF/proxy config is in the repo. The only guard is a 30 s statement timeout (`Gov.hs:255,267`). | "public; **not** rate-limited in-process — rate limiting is delegated to the reverse proxy / BFF, which this repository does not ship (see PG-13)". |
| DC-19 | Medium | `:47` "**Attestations** (`Query/Projected.hs`): Persistent/esqueleto over `palmares_attest`." | Live module is `Query/Attest.hs`, deliberately `rawSql "SELECT ??"` with bound parameters, **not** esqueleto (`Attest.hs:13-38`). `Projected.hs` is dormant (DC-13). | Replace with `Query/Attest.hs` and its four load-bearing decisions. |
| DC-20 | Medium | `:50-52` "`Query/Views.hs` … Idempotent — every statement is `CREATE OR REPLACE` / `CREATE ... IF NOT EXISTS`." | `sql/000_schema.sql:10-11` is `DROP SCHEMA IF EXISTS palmares CASCADE; CREATE SCHEMA palmares;` and the 19 views are plain `CREATE VIEW` (`sql/010_gov_views.sql`, `sql/020_views.sql`). Idempotence is by drop-and-recreate, which is why grants must be re-made every boot (`sql/040_grants.sql:3-6`) and why unpinned projection tables were nearly deleted (commit `71fa00f`). | "Idempotent by **dropping and re-creating** the schema in one transaction; `palmares_attest` must never be referenced from these files." |
| DC-21 | Medium | `:58-59` "Readiness is db-sync lag, not process liveness: red above `PALMARES_READY_MAX_LAG_SECONDS`". | `readyVerdict` (`Gov.hs:343-350`) has five checks: db reachable, lag, `drep_distr` epoch ≥ tip−1, network name == `PALMARES_NETWORK_NAME`, and — since `efb6c09` — the attestation projector's cursor lag (`readyAttestLagSeconds`). | List the five checks and the `Nothing`-passes rule for the projector. |
| DC-22 | Low | `:25` `mkPalmaresApp`; `:11`/offchain `:35` `runPalmaresActionWithPK`; `:23-24` "Full server = swagger :<\|> probe :<\|> private"; `:9-10` "Left for deploy/blueprint/limited queries"; `:69` probe "returns 503 when not synced". | Functions are `mkWebApp` (8 refs, 0 for `mkPalmaresApp`) and `runActionWithPK` (`Transactions.hs:127`). interaction-api's full server is swagger :<\|> probe :<\|> **status** :<\|> privateTransactions :<\|> privateService (`interaction-api/RestAPI.hs:262-276`); query-api has no private part at all. Blueprint, metrics-doc, reconcile, apply-*, new-operator-key, operator-address, sign-tx all run *before* any provider (`admin/Main.hs:663-720`). The attest-sync probe answers 200 for `Behind False` (`ChainsyncAPI.hs:60-63`). | Rename; list the provider-free commands; "503 when `Ahead`, `UpToDateButDifferentBlockHash` or way behind". |

### 1.4 `src/lib/onchain-lib/CLAUDE.md`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-23 | Medium | `:29` "Only MintingPolicy is parameterized." `:85` "Oracle NFT must mint before MintingPolicy compilation (parameterized by oracle AssetClass)." | `oracleNFTPolicyCompile :: TxOutRef -> CompiledCode …` (`OracleNFTPolicy.hs:57-60`) is parameterized by the seed. `mintingPolicyCompile :: ProtocolParams -> …` (`MintingPolicy.hs:424`) is parameterized by `ProtocolParams` = three validator script hashes **plus** the oracle token (`Protocol/Types.hs:24-33`). Profiles, Attestations, Disputes, Oracle validators are unparameterised ✓. | "Two scripts take a parameter: `OracleNFTPolicy` (seed `TxOutRef`, inlined) and `MintingPolicy` (`ProtocolParams`: validator hashes + oracle NFT). Mint the oracle NFT and deploy the three validators first." |
| DC-24 | Medium | `:77-78` "**Time**: any date carried in a datum is validated against the transaction's validity interval — never trusted as supplied (inherited fix #4)." | `attestationPeriod` is **deliberately not validated and must never be** (`Protocol/Types.hs:339-357`; commit `a3b36d4`). Only `attestationDate` and `disputeOpenedAt` are bounded. | "Every date the chain can know (issuance, dispute opening) is validated against the validity interval; `attestationPeriod` is self-reported by design and the read layer must label it `claimed_period`." |
| DC-25 | Low | `:79-81` "**Lookups**: … `readOracleParams`, `readOracleParams` is the live one. (The `unsafeGet*` profile helpers are currently UNCALLED …)" | True but self-contradictory as written. `unsafeGetProfile`, `unsafeGetProfileDatumAndValue`, `unsafeGetProtocolParamsFromProfileRefInput` have zero callers outside `Lookup.hs`; `readOracleParams`, `feeFor`, `checkFee` are live. | Rewrite the bullet; delete the three dead helpers (they are exported, so `-Wunused` cannot flag them). |
| DC-26 | Low | `:9` "**Validators**: Keep lambdas under ~80 lines." | Measured spans (signature to last line): `disputesLambda` 104 lines / 44 non-comment (`DisputesValidator.hs:82-185`), `attestationsLambda` 66/36, `profilesLambda` 58/26, `oracleLambda` 44/24, `mintingPolicyLambda` 31 + handlers 49-67. | State the unit ("non-comment lines") or raise the bound; disputes is within the intent. |

### 1.5 `src/lib/offchain-lib/CLAUDE.md` and `src/test/CLAUDE.md`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-27 | Low | offchain `:26-27` "**Lookups**: `utxoDatum'` for one UTxO's datum. `utxosDatums` when filtering…"; `:92` "architecture docs". | Neither helper name appears anywhere in `src` (0 refs). `Lookups.hs` uses `utxosAtAddresses`, `utxosWithNFT`, `utxosWithAsset`, `utxosToList` and the project's `authenticateStateUTxO` (12 refs). No architecture docs exist yet (`docs/architecture/` is empty at HEAD; being written in parallel). | Name the real helpers; link `docs/architecture/` once landed. |
| (DC-08) | — | test `:46-48` "no database". | See DC-08. | |
| (DC-12) | — | test `:7-8` property tests; `:14-16` privnet. | See DC-12. | |

### 1.6 ADRs

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-28 | Medium | ADR 0001 `docs/adr/0001-governance-data-substrate.md:12`: "`palmares` (fourteen read-only views, one materialized view, one SQL function)". | The same ADR says "19 views, 1 materialized view" (`:60`) and "nineteen views" (`:107`). Actual: 19 `CREATE VIEW` (`sql/010_gov_views.sql` ×13, `sql/020_views.sql` ×6), 1 `CREATE MATERIALIZED VIEW` (`sql/030_metrics.sql:40`), 1 `CREATE FUNCTION` (`sql/020_views.sql:24`). | "fourteen" → "nineteen". |
| DC-29 | High | ADR 0002 `:8-10`: write path "uses Atlas 0.14.1 with a commercial chain provider (Maestro), whose token is supplied from the environment"; `:27-28`: "A provider token is the only secret in the deployment"; `Status: proposed`; spike "to be run post-F0". | `compose.yaml:152-168,240-243` ships the **local-node + Kupo** provider and records the spike's measurement ("KUPO v2.12.0 AGAINST NODE 11.1.2 IS MEASURED … Probed 2026-10-22"). Secrets that exist besides a token: `BASIC_USER`/`BASIC_PASS`, `operation.prv` (24-word mnemonic, `admin/Main.hs:730-770`), `POSTGRES_PASSWORD`, `PALMARES_OWNER_PASSWORD`/`PALMARES_RO_PASSWORD`, `KOIOS_API_TOKEN`. Token lives in JSON, not env (DC-02). | Update ADR 0002: status `accepted` with the local-node provider as default and Maestro as the hosted alternative; record the Kupo probe numbers; replace "only secret" with the secret inventory. |
| DC-30 | Low | `src/exe/attest-sync/Main.hs:52` and `sql/050_roles.sql:3-4`: "ADR 0001 chose one database with role separation over two". | ADR 0001 never mentions roles, `palmares_owner`/`palmares_ro` or a second database (grep `role|database` → nothing relevant). The decision is recorded only in commit `cca13eb` and the SQL header. | Add a "Consequences" bullet to ADR 0001 (or a new ADR 0003 "Co-location and role separation") and cite it from the two comments. |
| DC-31 | Low | ADR 0001 `:38-39` "T1–T7 monitorable triggers … see the design notes in the originating repository"; `:46` "once T-SUBSTRATE-3/4 land"; `Status: accepted` while the PVC verdict is "open" (`:65`). | Neither the triggers nor the task ids exist in this repository. | Copy the T1–T7 triggers into the ADR; replace task ids with issue links; status "accepted (PVC sizing open)". |

### 1.7 `docs/deployment/*.md`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-32 | Medium | `attest-flow-smoke.md:138-142`: "**Neither service reports `attest-sync`'s lag.** `query-api`'s `/ready` and `/status` speak for the *governance* index … the three `palmares_attest` projection tables have no freshness field anywhere on the read surface." | Stale since `efb6c09` (2026-10-22): `/ready` now fails `indexer_behind` when the projector's `chain_cursor` lags db-sync's tip by more than `PALMARES_READY_MAX_LAG_SECONDS` (`Gov.hs:349`, `QueryAppMonad.hs:37-40`, `ServiceStatus.hs:92,116`). Still true: `/status` has no attestation block (`StatusResponse` = network + governance + epoch params, `QueryResponses.hs:542-549`), and a projector that *never started* passes (`Nothing` = no evidence). | "`/ready` fails on a stale projector; `/status` does not yet expose the projector's lag, and a projector that never ran is indistinguishable from a governance-only deployment." |
| DC-33 | Medium | `attest-flow-smoke.md:90-93`: "The generated document's `GYAddress` *description* says bech32 and is wrong about it". | The wrong text is authored in `src/lib/webapi-lib/Palmares/WebAPI/Utils.hs:44` and shipped in `docs/generated/swagger/interaction-swagger-api.json` (`GYAddress.description` = "Bech32-encoded Cardano address …", `format: cbor hex`, `maxLength: 114`). The published API contract is wrong and an internal doc apologises for it. | Change `Utils.hs:44` to "Raw CBOR hex of the address (114 hex characters for a base address). Bech32 `addr…` is refused." and regenerate; then delete the paragraph from the smoke doc. |
| DC-34 | Low | `attest-flow-smoke.md:4` "It is F1 check 11"; `koios-parity-gate.md:3` "F1 check 6"; `:53` `operation.prv` "the admin key". | "F1 check N" is defined nowhere in the repo (see §2). `operation.prv` is a 24-word BIP-39 **mnemonic** file written by `admin new-operator-key` (`admin/Main.hs:730-770`), which neither README nor `CLAUDE.md:15` mention. Admin command table ✓ (`admin/Main.hs:267-488` has no `claim-profile`, `open-dispute`, `resolve-dispute`); exit codes 0/1/2 ✓ (`scripts/smoke_attest_flow.sh:131,434`). | Drop the F1 numbering or add the checklist to `docs/`; document `new-operator-key` → fund → `operator-address` in README §10. |
| — | PASS | `koios-parity-gate.md` vs `scripts/reconcile_koios.sh` and `.github/workflows/reconcile.yml`. | Exit codes 0/1/2/3 (`reconcile_koios.sh:29-35`, `admin/Reconcile.hs:19`), warn-only + `continue-on-error: true` (`reconcile.yml:25`), artifact `koios-divergences` (`:62-66`), image override via `PALMARES_ADMIN_CMD` (`:55-58`) all match. Only the F1 numbering and the `GHCR_TOKEN` story in commit `e6a7fc5` are stale (superseded by `images.yml:60-68`). | None beyond DC-34. |

### 1.8 Generated Swagger (`docs/generated/swagger/*.json`)

| ID | Sev | Claim (document) | Reality | Fix |
|---|---|---|---|---|
| DC-35 | High | `interaction-swagger-api.json` `info.license.name = "GPL-3.0 license"`. | Authored at `src/exe/interaction-api/RestAPI.hs:220`. The project is Apache-2.0 (`LICENSE`, `palmares.cabal:9`, `README.md:94`); the query document says `Apache-2.0` (`query-api/RestAPI.hs:1741`) and `scripts/check_swagger.sh:33` asserts it — for the query document only. The write API's self-description claims a copyleft licence. | `RestAPI.hs:220` → `"Apache-2.0"`; extend `check_swagger.sh` to run over both documents. |
| (DC-33) | Medium | `GYAddress` "Bech32-encoded". | See DC-33. | |
| DC-36 | Low | `GYAssetClass` description differs: query doc "either \"lovelace\" or … delimited by dot" (Atlas's own `ToSchema`); interaction doc "`<56-char policy ID hex>.<asset name hex>`". | `addSharedSwaggerDescriptions` (`Utils.hs:39-59`) is called only by interaction-api (`grep` in `query-api/RestAPI.hs` → none), so it is not "shared". Four of its seven rows (`GYTime`, `GYPubKeyHash`, `DRepId`, `GovActionId`) match **no** definition in either document — silent no-ops, the trap commit `a3b36d4` found for `AttestationType`. Query-api profile ids reject `lovelace` (`invalid_asset_class`). | Apply the helper in query-api too; delete or test the no-op rows (a unit test that every key in the helper exists in at least one document). |
| DC-37 | Low | Versions: query `1.0.0`, interaction `3.0.0`, probes report `appVersion = "1.0.0"` (`Constants.hs:31`), package `0.1.0` (`palmares.cabal:3`). | Four unrelated version numbers for one release. | Derive all three from the cabal version (or document that API versions are contract versions). |
| DC-38 | Low | `ProfileType` enum `person_d_rep` (both docs). `Core/Types.hs:47,64` comments say the wire form is `person_drep`. `AttestationType` has a description in the interaction doc only; `DRepStatus` values `unknown`/`reserved` have no description. | `CamelToSnake` of `PersonDRep` really yields `person_d_rep`; the swagger (read from `ToJSON`) is right and the comments are wrong. | Fix the comments (or pick a `ConstructorTagModifier` that yields `person_drep` — a wire break, do it before first deploy); add `DRepStatus`/`AttestationType` descriptions in `apiSwagger`. |

### 1.9 `palmares.cabal`, `compose.yaml`, `.env.example`, `NOTICE`

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-39 | Low | `palmares.cabal:97-99` "Every `exposed-modules` / `other-modules` list in this file is present but comment-prefixed"; `:19-21` "The SQL and metric-catalog globs below are deliberately commented out"; `:40-41`. | All lists are live except five query-api modules (`:358-367`); the globs are live at `:29-32`; `:40-41` is a stale duplicate. `:378-380` "No atlas-cardano … in query-api" ✓ true. | Delete the two stale paragraphs and `:40-41`. |
| DC-40 | High | `compose.yaml:231-232`: "`operation.prv` is bind-mounted read-only … the `admin` CLI reads it from the working directory"; `:6` "`--profile write up -d` # + Kupo and the interaction API (the write path)". | The `interaction-api` service mounts only `node-ipc` and `./config` (`:246-250`) — no `operation.prv` (it does not need it). Its `environment` (`:236-245`) lacks `BASIC_USER`/`BASIC_PASS`, which `getBasicAuthFromEnv` requires or `die`s (`Auth.hs:54-63`); there is no `env_file:` and compose does not inject `.env` into containers. The `write` profile therefore cannot start as documented. No `attest-sync` service exists at all (DC-10). | Add `BASIC_USER: ${BASIC_USER:?}` / `BASIC_PASS: ${BASIC_PASS:?}` to the service; fix or delete the `operation.prv` comment; add an `attest-sync` service (needs `PG_CONN_STR`, `KUPO_URL=http://kupo:1442`, `ATLAS_CORE_CONFIG`, `./config` mount). |
| DC-41 | Low | `.env.example:4` "required by interaction-api + admin (fail-closed: they `die` if unset)" over `BASIC_USER`, `BASIC_PASS`, `CORS_ALLOWED_ORIGINS`; `:19` `BATCH_SIZE`; `:20` `FETCH_BATCH_SIZE=100000`. | Admin reads none of the three; CORS never dies (`CORS.hs:36-43`); `BATCH_SIZE` is dead; default is 10,000,000 (DC-03, DC-06). | Edit in step with README §11. |
| DC-42 | Low | `NOTICE:11-12` "see the dependency pins in `cabal.project` and the generated license report". | No license report exists (`grep -ri 'license.report'` → NOTICE only); nothing generates one. | Either add a `cabal-plan license-report` step whose output is committed, or drop the sentence. |

### 1.10 References to documents that are not in the repository

| ID | Sev | Claim | Reality | Fix |
|---|---|---|---|---|
| DC-43 | High | On-chain and off-chain code cite "the spec": `Protocol/Types.hs:198` ("The six the spec names"), `:273`, `:292` ("The five the spec names (§3)"), `:339` ("The spec requires it"), `:376` ("spec §4.3"); `MintingPolicy.hs:106` ("the spec's §3 glossary"); `DisputesValidator.hs:13` ("Spec §4.3"); `AttestationsValidator.hs:15`; `Utils.hs:258` ("the spec states it in one sentence"); `Storage.hs:162`; `Core/Types.hs:276`; `UnitTests/Claim.hs:6` ("from the spec (§2, §4.3)"); `experiments/dbsync-preprod/README.md:29` ("spec §4.1"). The generated `docs/metrics.md:94,199,264,383,444,516,537,563` and `resources/metric-formulas.json` link each formula to `docs/superpowers/design/f1-metric-formulas.md#…` / `f1-dbsync-data-layer.md`. | **No spec is committed.** `docs/` contains `adr/`, `deployment/`, `generated/`, `metrics.md` only; `docs/superpowers/` does not exist, so every "Spec:" link in the generated metrics doc is dead. The glossary that fixes the six profile kinds, the five attestation kinds, the claim rule ("prove you can spend as that credential") and the dispute semantics (§4.3) is therefore not reviewable — a reviewer cannot tell whether the validators implement the requirement or the requirement was edited to fit. | Commit the spec (or the relevant sections) under `docs/spec/` with stable anchors, and repoint `resources/metric-formulas.json` `spec` fields (then regenerate `docs/metrics.md`). Until then, the Haddocks should quote the sentence they rely on rather than cite a section number. |

**Ledger of external identifiers** (counts over `src docs scripts config compose.yaml README.md CLAUDE.md .github .env.example palmares.cabal experiments/*/README.md`; none resolve in-repo):

| Family | Examples | Occurrences | Where a reader would need them |
|---|---|---|---|
| "the spec" §n | §2, §3 glossary, §4.1, §4.3, §6 | 13 | validator requirements, kinds, claim rule, dispute semantics |
| F1 checks | "F1 check 3/6/8/11/12", "F1 checks 1-7 and 12" | 20 | what the CI gates and smoke scripts are *for* |
| Decision ids | D-1, D-4, D-7, D-9, D-10, D-15, D-17…D-31 | 40+ | why `/ready` thresholds, anchor verdicts, tally basis, eligibility rule are what they are |
| Finding ids | F-02, F-05, F-06, F-09, F-17, F-26 | 10 | hardening rationale in `Query/Attest.hs:185`, `Gov.hs` |
| Task ids | T-API-6…18, T-ATTEST-1…12, T-PARITY-1…6, T-SUBSTRATE-3/7/8, T-SQL-METRICS-2, T-METRIC §4, T-DATA §1.3 | 60+ | commit bodies, `check_swagger.sh:42`, `GovIds.hs:4` |
| Plans | "Plan A", "Plan B", "cut list C-10", "F1's variant B", "F2" | 20 | scope decisions (`Envelope.hs:114`, `RestAPI.hs:18`, `check_swagger.sh:75`) |
| Files | `f1-synthesis.md`, `f1-preprod-infra.md`, `f1-api-contract.md`, `f1-metric-formulas.md`, `f1-dbsync-data-layer.md`, `backend-api-requirements.md`, `docs/superpowers/F1-PROGRESS.md` | 16 | `experiments/*/README.md:6,14,27`, `config/reconcile-sample.preprod.json:23`, `QueryResponses.hs:251,365,401`, `Pages.hs:5`, `docs/metrics.md` |
| Owner decisions | "owner decision 2026-10-21" ×3 (`a3b36d4`, `05c83bd`, `e6a7fc5`), "Two of the five owner decisions" (`9781f1a`), "OWNER DECISION" (`43ab998`, `566da94`) | 6 | see §4 |

Of the three dated owner decisions: the `unknown` DRep status is findable in `docs/deployment/koios-parity-gate.md:94-99`; the GHCR namespace in `.github/workflows/images.yml:22-32`; the attestation kind + claimed period only in `Protocol/Types.hs` Haddocks and the swagger description. None has an ADR. "Five owner decisions" implies a list that is not in the repo.

---

## 2. Read-layer obligations delegated by on-chain comments

| ID | Obligation (source) | Verdict | Evidence |
|---|---|---|---|
| RL-1 | `profileCredential = Nothing` must be presented as **unclaimed, never verified** (`Protocol/Types.hs:272-275`, `Operations.hs:268`, `ServiceRequests.hs:46`). | **PASS** | `AttestProfileRow.credential :: Maybe Text` is published raw with `credential_is_script` decoded from the header byte (`Query/Attest.hs:272-285`); `/profiles` description: "`credential` is a claim and not a proof" (`RestAPI.hs:1380-1386`); `claimed=true/false` filter (`Attest.hs:221-224`). The word "verified" appears nowhere on the surface. Nit: there is no explicit `claim_status` field; a client must infer `unclaimed` from `null`. |
| RL-2 | `attestationPeriod` must be shown as `claimed_period` **beside** `issued_at`, never sorted/filtered as verified (`Protocol/Types.hs:355-357`). | **PASS** | Field `claimed_period` (`QueryResponses.hs:1779-1790`); `order_by` enum has no period key (`Attest.hs:292-298`); filters are `date_from`/`date_to` on issuance only (`Attest.hs:322-333`); route description says so (`/attestations`). Nit: the issuance field is named `date`, not `issued_at` as the on-chain comment says — pick one. |
| RL-3 | A disputed attestation is **never hidden or deleted**; the dispute is shown **beside** it ("contested") (`Protocol/Types.hs:375-378,457`, `DisputesValidator.hs:13-15`, `Storage.hs:160-162`). | **PARTIAL** | Never hidden ✓ (projection is upsert-only, `Storage.hs`; no delete route). Shown beside it ✓ **only on the detail route**: `GET /attestations/{id}` inlines ≤ 50 disputes in one transaction (`Attest.hs:368-381,422-423`). **List rows carry no marker**: `AttestationRow` has no `dispute_count`/`contested`/`open_disputes` field (`QueryResponses.hs:1784-1800`), so `GET /attestations` and the track record `GET /profiles/{id}/attestations` show an attestation with an *upheld* dispute as `accepted: true` and nothing else. The word "contested" occurs only in a route description (`RestAPI.hs:1441`). |
| RL-4 | A **lineage** attestation (subject = an attestation id) must **not** be presented as "pending", because it can never be accepted (`AttestationsValidator.hs:14-33`, `UnitTests/Attestation.hs:301-305`: "That is T-ATTEST-9's business"). | **FAIL** | T-ATTEST-9 (`87807f1`) landed without it. `AttestationRow` has only `accepted :: Bool` and `subject :: ProfileRefAC` (`QueryResponses.hs:1784-1800`); the projection stores the subject id untyped as `GYAssetClass` (`Storage.hs:146`); nothing in `Ingestion.hs`/`Attest.hs` distinguishes a profile subject from an attestation subject (grep `lineage` → comments only). So `GET /attestations?accepted=false` and `?issuer=<id>` return lineage records as unaccepted claims, exactly the reading the validator comment calls "the real defect". Fix: add `subject_kind: profile \| attestation` (derivable by checking whether `subject_profile_id` exists in `profile_projection`) and a three-valued `status: accepted \| pending \| standalone`. |
| RL-5 | `/profiles/by-credential/{credential}` with several claimants must report all of them and pick no winner (`QueryResponses.hs:1750-1754`, `Storage.hs:124-128`). | **PASS** | Paged, `total` is the claimant count, ordered oldest claim first, CIP-129 only with 400 otherwise (`RestAPI.hs:1424-1452`, `Attest.hs:121-125`, handler `RestAPI.hs:1565-1577`); `attest-flow-smoke.md:148-151` and the script assert `total >= 1`. |
| RL-6 | Duplicate credential claims are "reported as `contested` rather than the ingest path refusing the second claim" (`Storage.hs:124-126`, `UnitTests/AttestSchema.hs:161`). | **PARTIAL** | The only signal is `total > 1` on the by-credential route. `GET /profiles/{id}` and `/profiles` rows do not say that the row's credential is also claimed elsewhere; no `contested`/`claimant_count` field exists. A verification screen that starts from a profile (not from a credential) cannot see the contest. |

---

## 3. Product gaps versus promises

| ID | Promise (where) | What exists | Gap / suggested milestone |
|---|---|---|---|
| PG-01 | "publishes it through a free public API **and explorer**" (`README.md:6-7`); "rendered next to the number" (`:22`); "the API and the explorer need no account" (`:29-30`). | No frontend, no `web/`, no link to an explorer repository. Hints of one: `query-api/Main.hs:39` ("the frontend's `gen:api` input"), `CORS.hs:50` ("staleness chip"), `/pages/*` aggregate routes, `gov.cardano.vip` URLs in scripts. | Add a README link to the explorer repository or mark the explorer as "F2, not yet public". Until then "API" only. |
| PG-02 | The compose stack runs "the complete product on preprod" (`README.md:43,84,113-119`). | `compose.yaml` has no `attest-sync`; the `write` profile's `interaction-api` cannot boot without `BASIC_*` (DC-40). The attestation read routes would always answer empty pages. | Fix now (F1): add the service + env, then run `scripts/smoke_attest_flow.sh` against the compose stack and record it. |
| PG-03 | "mainnet follows once the substrate and validators have soaked" (`README.md:43-44`). | Blockers, none tracked in one place: (a) ADR 0001:111 — mainnet needs a 48–64 GB x86_64 host; the Pi cluster is preprod-only; (b) `images.yml:74,116` builds **linux/arm64 only** — there is no amd64 image for the mainnet host; (c) PVC unsized (ADR 0001:65,94-96); (d) ADR 0002 still "proposed" (DC-29); (e) Kupo/node compatibility must be re-probed on every node bump (`compose.yaml:159-168`); (f) nothing is deployed — `config/config_palmares_validators.json` absent, script hashes still moving (commits `9781f1a`, `b22235c`, `e6a7fc5`…), blueprint uncommitted (DC-09); (g) no cluster manifests in repo (DC-11); (h) Kupo `--match '*' --since origin` index size/time unmeasured (`compose.yaml:204-205`); (i) `PALMARES_NETWORK_NAME` defaults to `preprod` (DC-07). | Write `docs/adr/000N-mainnet-promotion-criteria.md` listing (a)–(i) with owners; add `linux/amd64` to `images.yml` platforms before any x86 deployment. |
| PG-04 | Admin CLI "administers the oracle, and issues or accepts attestations" (`admin/Main.hs:655`); the smoke doc needs claim/dispute/resolve. | 20 commands (`admin/Main.hs:267-488`). Missing: `claim-profile`, `open-dispute`, `resolve-dispute` (`attest-flow-smoke.md:16-22`), a `--drep-id`/DRep-credential printer (`d680cc7`: "nothing here prints it"), read commands over `palmares_attest` (`query-oracle` is the only read). `delete-profile` is absent by design (`:59`). | F1: `resolve-dispute` in the CLI (the admin *must* sign it anyway); `operator-drep-id`. F2: the rest. |
| PG-05 | "The write path needs one key of your own" / Maestro (ADR 0002). | A self-hosted write path exists in compose (local node + Kupo, measured 2026-10-22) but is undocumented in README/ADR; Kupo index cost unmeasured. | Update ADR 0002 (DC-29) and README §2; measure the Kupo origin sync. |
| PG-06 | "signed in your wallet (CIP-30 / CIP-95)" (`README.md:33`). | No wallet integration code; CIP-95 is mentioned only in README. The only signer is `admin sign-tx` (`admin/Main.hs:807-823`), whose output is pinned against one recorded CIP-30 witness set (`UnitTests/SignTx.hs:56-60`). Claiming a **DRep key** credential adds `mustBeSignedBy <drep key hash>` (`Operations.hs`, `claimProofSkeleton`; `attest-flow-smoke.md:96-99`) — a signature a CIP-30-only wallet cannot produce for a DRep key; CIP-95 `signTx` is required and has never been exercised. | F2: a reference wallet flow (or at least a documented manual test with a CIP-95 wallet on preprod). |
| PG-07 | "Koios is used as an independent cross-check" (`README.md:17`). | A nightly, warn-only, `continue-on-error` job over a pinned 37-DRep/24-action sample (`reconcile.yml`, `config/reconcile-sample.preprod.json`) plus an offline replay test. Not continuous, not per-request, preprod only. | Wording: "cross-checked nightly against Koios on a pinned sample; see `docs/deployment/koios-parity-gate.md`". |
| PG-08 | Operability of a public service (implied by §4 "complete product"). | No alerting, no notification hooks, no Prometheus endpoint on our services (only Kupo's `/health` is scraped, `compose.yaml:218-220`); `/ready` + `/status` only. `attest-sync` lag not on `/status` (DC-32). | F2: expose `attest.lag_seconds` on `/status`; `/metrics` text endpoint; document what to page on. |
| PG-09 | "Data export" (contributor expectation). | CSV on seven governance routes (`/dreps`, `/votes`, `/gov-actions`, `/delegations`, `/spos`, `/treasury-withdrawals`, `/drep/{id}/delegators` — swagger `produces`). None for attestations, by stated design (`RestAPI.hs:1372-1377`). No bulk dump. | Fine for F1; say so in README §6/§11. |
| PG-10 | Pagination / i18n. | Offset pagination with bounded limits and a cursor on `/activity` ✓. No i18n anywhere (English-only error messages and `docs/metrics.md`); not promised. | Not a gap unless the explorer promises it. |
| PG-11 | Six profile kinds, five attestation kinds (`Protocol/Types.hs:238-258, 307-325`). | All reachable: `ProfileType` 6 values and `AttestationType` 5 values in both documents; `kind` filters on `/profiles` and `/attestations`; `ClaimProfileRequest.kind`, `IssueAttestationRequest.kind`. Spelling `person_d_rep` is awkward (DC-38). | Decide the tag spelling before first deploy. |
| PG-12 | CIP-57 blueprint "committed" (`README.md:70`). | Generated on demand only (DC-09). | F1: commit + gate. |
| PG-13 | Public read API (`src/exe/CLAUDE.md:77`). | No rate limiting, no BFF, no SLO; the 30 s statement timeout (`Gov.hs:267`) is the only protection; CORS allowlist only. | F1 before public exposure: a reverse-proxy rate limit + an ADR (see §4). |
| PG-14 | Lineage attestations are "a record the spec asks for" (`AttestationsValidator.hs:15`). | Mintable, never acceptable, and mislabelled as pending on the read surface (RL-4). | F1/F2: `subject_kind` + three-valued status. |
| PG-15 | "contested" on attestations and on duplicate credential claims. | Only derivable from the detail route / `total > 1` (RL-3, RL-6). | F2: `dispute_count`, `open_dispute_count` on list rows; `claimant_count` on profile rows. |
| PG-16 | "Koios … never a source" and "no opaque scores" (`README.md:17,24-25`). | Holds: no Koios read in the serving path; no composite score field in any DTO. | None. |

---

## 4. ADR hygiene

**Status.** ADR 0001 "accepted" (with the PVC fork open, DC-31); ADR 0002 "proposed" although the shipped stack already embodies a different answer (DC-29). There is no ADR index.

**Decisions that live only in commit messages or code comments** (each deserves at least a paragraph in an ADR, because the commit log is not what a new reviewer reads):

| Decision | Where it is recorded today | Suggested ADR |
|---|---|---|
| Keep PlutusTx traces in production scripts (+1.8–3.4 % size) | `palmares.cabal:69-95`, commit `43ab998` | 0003 On-chain diagnosability |
| Disputes and all datum-shape changes land **before the first deployment**; constructor indices append-only from then on | `Protocol/Types.hs:27-30`, commits `405c8d9`, `3bc3297`, `a3b36d4` | 0004 On-chain contract freeze / upgrade policy |
| Six profile kinds, five attestation kinds as closed datum enums; no validator branches on them | `Protocol/Types.hs:196-210, 290-305`, commit `3bc3297` | 0005 Registry vocabulary (needs the spec, DC-43) |
| `attestationPeriod` self-reported and unvalidated; `attestationDate` bounded; date window = 2× the honest width | `Protocol/Types.hs:339-357`, `Utils.hs`, commits `a3b36d4`, `9781f1a` | 0004 or 0006 Time semantics |
| Third DRep status `unknown` instead of guessing | `koios-parity-gate.md:94-109`, `Core/Types.hs:480-486`, commit `05c83bd` | 0007 Governance status vocabulary |
| GHCR namespace `mariusgeorgescu`, images at tags only, arm64 only | `images.yml:7-32`, commit `e6a7fc5` | 0008 Build & release |
| No admin actions over HTTP; `resolve-dispute` stays on HTTP | `Core/Actions.hs`, commit `d55d2cc` | 0009 Write-API authorisation model (with Basic auth) |
| Credential lookup accepts CIP-129 only | `Query/Attest.hs:97-125`, commit `87807f1` | 0007 |
| One database (`cexplorer`) + two roles, `search_path` pinning | `sql/050_roles.sql:1-19`, commits `cca13eb`, `71fa00f` | 0010 Database co-location and roles (DC-30) |
| Views dropped and re-created at every boot; grants re-made | `sql/000_schema.sql`, `sql/040_grants.sql`, commit `01c9d97` | 0010 |
| attest-sync wipes and re-syncs from origin on schema-version or policy change | `attest-sync/Main.hs:96-110`, `Storage.hs:302-316` | 0004 |
| Kupo `--match '*' --since origin` | `compose.yaml:185-205` | 0002 revision |
| Local-node provider as the shipped write path | `compose.yaml:152-168` | 0002 revision |
| `rationale_rate` denominator excludes unassessable anchors ("OWNER DECISION WORTH REVISITING") | commit `566da94`, `resources/metrics/rationale_rate_v1.sql` | 0011 Metric definitions (or the spec) |
| 30 s read ceiling; `/ready` thresholds 300 s/120 s | `Gov.hs:255-267,352-362`, commit `3b198f9` | 0012 Public API SLOs |
| `admin sign-tx` ships as the reference signer | commit `d680cc7`, `attest-flow-smoke.md:51-71` | 0009 |

**ADRs a reviewer would expect and will not find:** admin key custody and rotation (mnemonic in `operation.prv`, `rotate-admin`, no HSM, who holds it in production); upgrade/migration policy (validator redeploy = new hashes = new minting policy = orphaned data; `palmares_attest` wipe = full Kupo re-sync; view recreation); data retention (nothing is ever deleted; disputes and dust are permanent; Kupo index growth); rate limiting / BFF ownership; public-API SLOs and error budget; secrets inventory and injection (`.env` via direnv vs compose vs cluster); mainnet promotion criteria (PG-03).

---

## 5. Onboarding: what a new contributor cannot do from the docs alone

| Need | Status | Evidence / fix |
|---|---|---|
| Build without Nix on Linux/macOS | Not documented, but **CI already does it**: `ci.yml:53-108` (apt list, blst 0.3.15 from source, `libblst-any.pc` alias, `haskell-actions/setup` GHC 9.6.6 / cabal 3.10). | Copy that recipe into `docs/runbooks/build-without-nix.md`; README §10 says "GHC 9.6.6 via Nix + direnv" only. |
| Run tests without Postgres | Impossible by design (`Test/Pg.hs:11-14`); README omits it (DC-08). | One `docker run` line + the env var. Consider `tasty` pattern flags to run the pure suites alone. |
| Find the Kubernetes manifests | Not in repo (DC-11); scripts assume `kubectl --context minirack-lan`. | Link the manifests repo; make `PSQL` overrides the documented path. |
| Obtain a Maestro token | `config/config_atlas.example.json:3` has `REPLACE_ME`; no pointer to the provider, no statement that it is optional (local node works). | One sentence in README §11 + ADR 0002. |
| Generate `operation.prv` | `admin new-operator-key` exists and refuses to overwrite (`admin/Main.hs:730-770`), prints both address forms (`:780-799`). Not mentioned in README or `CLAUDE.md:15` ("admin key, never commit"). | README §10 "First deploy" sequence. |
| Deploy the validators step by step | Pieces exist: `new-operator-key` → fund the printed address → `deploy-reference-scripts` writes `config/config_palmares_validators.json` (`admin/Main.hs:540-544`) → `apply-roles` (needs `PALMARES_ADMIN_CONN_STR`, two passwords) → `apply-indexes` → `KUPO_SINCE` tip start (`compose.yaml:196-202`) → services. Nowhere written as a sequence; `compose.yaml:8-10` is the closest. | `docs/runbooks/first-deploy.md`. |
| Understand what `ATTEST_SMOKE_DREP_ID` is and how to get it | "nothing in the repo prints it" (`attest-flow-smoke.md:85-86`). | PG-04. |
| Regenerate the blueprint / swagger / metrics doc | Swagger + metrics doc gated and documented in `ci.yml`; blueprint not (DC-09). | |
| Know the API error contract | Good: `ErrorCode` enum + `check_swagger.sh`. | |
| Know what "F1 check 6", "D-20", "Plan B" mean | Not possible (DC-43 ledger). | |

---

## 6. Licensing

| Check | Result |
|---|---|
| `LICENSE` is Apache-2.0; `palmares.cabal:9-10` `license: Apache-2.0`, `license-file: LICENSE` | ✓ |
| `NOTICE` names the MIT-licensed ancestor and the retained MIT text | ✓ (`NOTICE:4-9`, `licenses/LICENSE.decentralized-belt-system.MIT` is the full MIT text with the 2025 copyright) |
| `licenses/` matches `NOTICE` | ✓ one file, named in `NOTICE:9` and `palmares.cabal:28` |
| `extra-source-files` ships `NOTICE` + `licenses/*` | ✓ (`palmares.cabal:27-28`); all four Dockerfiles `COPY LICENSE NOTICE ./` and `COPY licenses` (`Dockerfile.*:29-30`); `scripts/check_packaging.sh` enforces it |
| Per-file headers | None: 0 files under `src/` contain `SPDX` or `Copyright`. Apache-2.0 does not require them, but `NOTICE:6` says "Portions of src/lib/ and src/exe/ are derived from that work" without saying which; `extraction-keep.txt` is the de-facto list (69 paths, pre-rename). Recommendation: reference that list from `NOTICE` (or add `SPDX-License-Identifier: Apache-2.0` headers to all files and `-- Derived from Decentralized-Belt-System (MIT)` to the extracted ones). |
| Third-party licence report | `NOTICE:12` promises "the generated license report"; none exists (DC-42). |
| Published API licence | interaction-api Swagger says **GPL-3.0** (DC-35, High). |
| Vocabulary gate | `scripts/check_vocabulary.sh` keeps the inherited licence file name (attribution, not a leftover) ✓. |

---

## 7. Deliverables

### 7.1 Docs debt, ranked

| Rank | ID | Sev | File:line | Exact edit |
|---|---|---|---|---|
| 1 | DC-01 | High | `README.md:21-23`; `src/lib/offchain-lib/Palmares/Metrics/Doc.hs:38`; `Metrics/Catalog.hs:11`; then regenerate `docs/metrics.md` | Replace "`Query.Metrics` looks each statement up … no second copy" with: "`/metrics/formulas` publishes these statements verbatim; the served DRep numbers come from `palmares.drep_metrics`, a batched implementation of the same formulas, and `sql/checks/070_drep_metrics.sql` asserts the two agree on preprod." (Or make the matview consume the embedded files and keep the sentence.) |
| 2 | DC-43 | High | `docs/spec/` (new); `resources/metric-formulas.json` `spec` fields | Commit the spec sections cited (§2, §3 glossary, §4.1, §4.3, §6) and `f1-metric-formulas.md`; repoint links; regenerate `docs/metrics.md`. |
| 3 | DC-17/18 | High | `src/exe/CLAUDE.md:20,42-59,77-78` | Rewrite "HTTP API Servers" and "Query API Specifics" from `QueryAppMonad.hs:4-15` and `Main.hs:57-61`; "public, **not** rate-limited in-process; rate limiting is a reverse-proxy concern this repo does not ship". |
| 4 | DC-40/DC-10 | High | `compose.yaml:231-250`, new `attest-sync` service | Add `BASIC_USER: ${BASIC_USER:?}`, `BASIC_PASS: ${BASIC_PASS:?}`; delete the `operation.prv` sentence; add the `attest-sync` service to the `write` profile. |
| 5 | DC-02/DC-29 | High | `README.md:31-33`; `docs/adr/0002-write-path-provider.md` | README: "write routes are Basic-auth protected; provider is a local node + Kupo by default, Maestro optional; token lives in the Atlas core config". ADR: status accepted, record the Kupo probe, replace "only secret" with the inventory. |
| 6 | DC-35 | High | `src/exe/interaction-api/RestAPI.hs:220`; `scripts/check_swagger.sh` | `"GPL-3.0 license"` → `"Apache-2.0"`; run the licence assertion over both documents. |
| 7 | DC-03/04/05/06/07 | High/Med | `README.md:141-156`; `.env.example:4,19-20` | Rebuild the env table from the `lookupEnv` grep in this report: drop `admin` from `BASIC_*`; `PG_CONN_STR` fail-closed (code fix) ; add `attest-sync` to the config rows; delete `BATCH_SIZE`; `FETCH_BATCH_SIZE` default 10000000; add the 11 missing names. |
| 8 | DC-08 | Medium | `README.md:104-110`; `src/test/CLAUDE.md:46-48` | Add the Postgres prerequisite and `PALMARES_TEST_PG_CONN_STR`. |
| 9 | DC-09 | Medium | `README.md:70`; `.github/workflows/ci.yml` | Commit `docs/generated/palmares-blueprint.json` + a drift step, or reword the row. |
| 10 | DC-32/33 | Medium | `src/lib/webapi-lib/Palmares/WebAPI/Utils.hs:44`; `docs/deployment/attest-flow-smoke.md:90-93,138-142` | Fix the `GYAddress` text at source and regenerate; replace the "neither service reports" paragraph with the `/ready` rule and the `/status` gap. |
| 11 | DC-13/19 | Medium | `CLAUDE.md:56-59`; `src/exe/CLAUDE.md:47,55` | Point at `offchain-lib/Palmares/Metrics/Catalog.hs`, `query-api/Query/Attest.hs`, `RestAPI.hs`; delete or label the dormant modules. |
| 12 | DC-20/21 | Medium | `src/exe/CLAUDE.md:50-52,58-59` | "drop-and-recreate in one transaction"; list the five readiness checks. |
| 13 | DC-23/24 | Medium | `src/lib/onchain-lib/CLAUDE.md:29,77-78,85` | Two parameterised scripts; "`attestationPeriod` is self-reported by design". |
| 14 | DC-28 | Medium | `docs/adr/0001-governance-data-substrate.md:12` | "fourteen" → "nineteen". |
| 15 | DC-11 | Medium | `README.md:133-134` | Name the manifests repository and the ConfigMap command. |
| 16 | DC-12/14/15/16/22/25/26/27/30/31/34/36/37/38/39/41/42 | Low | as cited | Stale names (`mkPalmaresApp`, `runPalmaresActionWithPK`, `utxoDatum'`, `Id.hs`), stale cabal comments, no-op swagger rows, version numbers, `person_drep` comment, NOTICE report sentence, experiments row, layout table. |

### 7.2 Product gaps

| ID | Gap | Evidence | Milestone |
|---|---|---|---|
| PG-02 | Attestation flow cannot run on the documented stack (no `attest-sync` service; write profile cannot boot) | `compose.yaml` service list; `Auth.hs:54-63` | F1 — now |
| PG-03 | Mainnet blockers untracked; no amd64 images | ADR 0001:111; `images.yml:74,116` | F1 — ADR; F2 — amd64 build |
| PG-12 | Blueprint not committed/gated | `admin/Main.hs:668-675` | F1 |
| PG-13 | No rate limiting / SLO for a public API | `Envelope.hs:114`, `RestAPI.hs:9-10` | F1 before public exposure |
| PG-14 | Lineage attestations read as "pending" (RL-4) | `QueryResponses.hs:1784-1800` | F1/F2 |
| PG-04 | Admin CLI lacks `resolve-dispute` (admin-signed anyway), `claim-profile`, `open-dispute`, DRep-id printer | `admin/Main.hs:267-488` | F1 (`resolve-dispute`, drep-id); F2 rest |
| PG-01 | No explorer in or linked from the repo | `README.md:6-7` | F2 / link |
| PG-05 | Self-hosted write path undocumented; Kupo cost unmeasured | `compose.yaml:204-205` | F1 docs; F2 measurement |
| PG-06 | CIP-95 wallet claim flow never exercised | `README.md:33`; `SignTx.hs` | F2 |
| PG-08 | No alerting/metrics endpoint; projector lag not on `/status` | `StatusResponse` | F2 |
| PG-15 | No `contested`/`dispute_count` on list rows (RL-3, RL-6) | `QueryResponses.hs:1760-1800` | F2 |
| PG-07 | Koios cross-check is nightly sample parity | `reconcile.yml` | wording only |
| PG-09/10/11/16 | CSV scope, i18n, kind spelling, no scores | — | wording / decide before deploy |

### 7.3 Proposed documentation structure

```
README.md                      product promise, two doors (corrected), 10-minute quickstart, links below
docs/
  spec/                        the protocol spec the code cites (§2, §3 glossary, §4.x, §6) — DC-43
    attestation-protocol.md
    metric-formulas.md         (source of the `spec` links in resources/metric-formulas.json)
    api-requirements.md        (what QueryResponses.hs calls backend-api-requirements §9/§10/§12)
  architecture/                being written by other agents now — reference, do not duplicate:
                               services & data paths, schemas, on-chain/off-chain type flow, trust boundaries
  adr/
    README.md                  index with status column; 0001 (fix count, add roles/co-location),
                               0002 (revise: local-node default), 0003… from §4 of this report
  runbooks/
    build-without-nix.md       lifted from ci.yml:53-108
    local-stack.md             compose profiles incl. attest-sync, env passthrough, smoke scripts
    first-deploy.md            new-operator-key → fund → deploy-reference-scripts → apply-roles → apply-indexes → KUPO_SINCE
    operations.md              /ready semantics (five checks), lag knobs, matview refresh, re-sync procedures
    koios-parity-gate.md       (move from deployment/)
    attest-flow-smoke.md       (move from deployment/, drop the stale paragraphs)
    secrets.md                 inventory: BASIC_*, operation.prv, Postgres roles, provider token, KOIOS token
  api/
    README.md                  error contract, pagination, CSV routes, address/asset-class formats (hex, not bech32)
    generated/swagger/*.json   (unchanged, CI-gated) + palmares-blueprint.json (new, CI-gated)
  metrics.md                   (generated; wording fix DC-01)
  audit/                       this series
CLAUDE.md + src/**/CLAUDE.md   keep, but each "File reference"/"Specifics" paragraph must cite a real path;
                               add a CI grep that every backticked `path.hs` in a CLAUDE.md exists and is in palmares.cabal
```

---

## 8. Evidence appendices

### A. Environment variables: what the code reads vs what README §11 says

| Variable | Read by (file:line) | Code default | Fail-closed? | README §11 row |
|---|---|---|---|---|
| `BASIC_USER`, `BASIC_PASS` | `webapi-lib/.../Auth.hs:56-57` ← `interaction-api/Main.hs:64` | none | yes (`die`) | says "interaction-api, admin" — admin is wrong (DC-03) |
| `CORS_ALLOWED_ORIGINS` | `CORS.hs:39` ← query-api, interaction-api, attest-sync probe (`attest-sync/Main.hs:73`) | `[]` = deny all cross-origin | no (silently deny-all) | "required; both APIs" — neither (DC-06) |
| `PG_CONN_STR` | `query-api/Main.hs:87`, `attest-sync/Main.hs:76` | `host=postgres user=postgres password=postgres dbname=cexplorer` / `host=localhost …` | **no** | "required" — wrong (DC-04) |
| `PALMARES_PG_OWNER_CONN_STR` | `query-api/Main.hs:100` | falls back to `PG_CONN_STR` | n/a | missing (only `.env.example:15`) |
| `ATLAS_CORE_CONFIG` | `interaction-api/Main.hs:58`, `attest-sync/Main.hs:81`, `admin/Main.hs:786,838` | file `config/config_atlas.json` | yes (`die`) in all three | omits attest-sync (DC-05) |
| `DEPLOYED_VALIDATORS_CONFIG` | `interaction-api/Main.hs:59`, `attest-sync/Main.hs:84`, `admin/Main.hs:827` | file `config/config_palmares_validators.json` | yes for the two services; admin degrades to `Left ProviderCtx` | omits attest-sync (DC-05) |
| `PORT` | `WebAPI/Utils.hs:20` ← 8082 / 8083 / 8084 | per service | no | ✓ |
| `KUPO_URL` | `attest-sync/Main.hs:75` | `http://localhost:1442` | no | ✓ |
| `BATCH_SIZE` | **nowhere** | — | — | listed (DC-06) |
| `FETCH_BATCH_SIZE` | `attest-sync/Main.hs:113-114` | `10_000_000` | no | says `100000` (DC-06) |
| `ROLLBACK_MARGIN` | `attest-sync/Main.hs:117-118` ← `Constants.hs:35` | 2160 | no | ✓ |
| `PALMARES_VIEW_REFRESH_SECONDS` | `Query/Refresh.hs:103-106` | 300 | no | ✓ |
| `PALMARES_READY_MAX_LAG_SECONDS` | `Query/Gov.hs:366`; also `admin/Reconcile.hs:93` | 300 | no | ✓ (admin use undocumented) |
| `PALMARES_AMBER_LAG_SECONDS` | `Query/Gov.hs:370` | 120 | no | ✓ |
| `PALMARES_FRESHNESS_POLL_MS` | `Query/Gov.hs:374` | 5000 | no | missing |
| `PALMARES_NETWORK_NAME` | `Query/Gov.hs:382` | `preprod` (drives `/ready`'s network check) | no | missing (DC-07) |
| `PALMARES_ADMIN_CONN_STR` | `admin/Main.hs:863` (`apply-indexes`, `apply-roles`) | none | yes | missing |
| `PALMARES_OWNER_PASSWORD`, `PALMARES_RO_PASSWORD` | `admin/Main.hs:694-695` (`apply-roles`) | none | yes | missing |
| `PALMARES_API`, `KOIOS_API`, `KOIOS_API_TOKEN` | `admin/Reconcile.hs:91-92,403` | `""` / preprod Koios / none | `reconcile_koios.sh:13` requires `PALMARES_API` | missing |
| `PALMARES_TEST_PG_CONN_STR`, `PALMARES_FIXTURE_PG_CONN_STR` | `Test/Pg.hs:48`, `UnitTests/MetricFixture.hs:241` | none | test `die`s / fixture skips | missing (DC-08) |
| `MAESTRO_API_KEY` | nowhere (correct: `README.md:158`) | — | — | ✓ |

### B. Admin CLI inventory (`src/exe/admin/Main.hs:267-488`, dispatch `:663-720`, `:531-636`)

| Command | Needs provider (`ATLAS_CORE_CONFIG`)? | Needs `operation.prv`? | Needs deployed config? | Notes |
|---|---|---|---|---|
| `new-operator-key` | no | writes it (refuses to overwrite, mode 0600) | no | undocumented in README/CLAUDE.md |
| `operator-address` | config only (network id, `:780-799`) | yes | no | prints bech32 **and** raw hex |
| `sign-tx` | no | yes | no | stdin tx hex → stdout witness-set hex (`:807-823`) |
| `write-blueprint` | no | no | no | output not committed (DC-09) |
| `write-metrics-doc` | no | no | no | CI-gated |
| `reconcile-koios` | no | no | no | exit 0/1/2/3 |
| `apply-indexes`, `apply-roles` | no (`PALMARES_ADMIN_CONN_STR`) | no | no | one-shot "Kubernetes Job" per `:685` |
| `deploy-reference-scripts` | yes | yes | no → writes it (`:540-543`) | |
| `pause-protocol`, `unpause-protocol`, `set-fees`, `set-min-utxo-value`, `set-dispute-deposit`, `rotate-admin`, `cleanup-dust` | yes | yes | yes | admin-signed oracle actions |
| `query-oracle` | yes | yes (file is read before dispatch, `:830-831`) | yes | read-only, used by the smoke script |
| `update-profile`, `issue-attestation`, `accept-attestation` | yes | yes | yes | |
| **absent** | — | — | — | `claim-profile`, `open-dispute`, `resolve-dispute`, a DRep-id printer, any `palmares_attest` read, `delete-profile` (by design, `:59`) |

### C. SQL object inventory (backs DC-28)

`sql/010_gov_views.sql` (13 views): `anchor`, `sync_state`, `drep_cert`, `drep_interval`, `drep`, `action_window`, `thresholds`, `threshold_map`, `cc_cold_interval`, `vote`, `drep_epoch_power`, `vote_delegation`, `live_delegation`.
`sql/020_views.sql` (6 views + 1 function): `drep_epoch_delegators`, `vote_tally`, `gov_action`, `committee_member`, `treasury_withdrawal`, `activity`; `FUNCTION palmares.eligible_actions(bigint, int)` (`:24`).
`sql/030_metrics.sql`: `MATERIALIZED VIEW palmares.drep_metrics` (`:40`).
`sql/040_grants.sql`, `sql/050_roles.sql`: grants/roles only. `sql/indexes/001_gov_indexes.sql`: 28 indexes on db-sync tables (applied by `admin apply-indexes`, not at boot).
Total: **19 views, 1 materialized view, 1 function, 0 tables** — matching ADR 0001's measurement rows, not its Decision sentence.

### D. Symbols named in the CLAUDE.md files, checked against `src/`

| Named in a CLAUDE.md | Exists? | Actual |
|---|---|---|
| `mkPalmaresApp` (exe:25) | no | `mkWebApp` (`query-api/RestAPI.hs`, `interaction-api/RestAPI.hs:288`) |
| `runPalmaresActionWithPK` (exe:11, offchain:35) | no | `runActionWithPK` (`TxBuilding/Transactions.hs:127`) |
| `utxoDatum'`, `utxosDatums` (offchain:26) | no | `utxosAtAddresses`, `utxosWithNFT`, `utxosWithAsset`, `authenticateStateUTxO` |
| `SafeOnchainLogic` (offchain:46) | no — stated as not extracted | ✓ consistent |
| `liveprojection`, `Query.Live` (exe:48) | no — stated as absent | ✓ consistent |
| `Query/Metrics.hs` (exe:55, root:56 via `query-api/Metrics/Catalog.hs`) | no | `offchain-lib/Palmares/Metrics/Catalog.hs`; served in `RestAPI.hs:254` |
| `Query/Projected.hs`, `Query/Pages.hs`, `Query/Aggregates.hs` (root:58-59, exe:47) | on disk, **not compiled** (`palmares.cabal:357-367`) | `Query/Attest.hs` |
| `Onchain/Protocol/Id.hs` (root:49, offchain:78) | compiled, **zero callers** | `Utils.nameFromTxOutRef`, `CIP68.generateRefAndUserTN` |
| `unsafeGetAttestation` (onchain:81) | never existed — stated | ✓ consistent |
| `claimedPeriodParser`, `outputIdParser`, `profileDataParser`, `assetClassParser`, `chainSyncTableNames`, `authenticateStateUTxO`, `getOracleRefInputSkeleton`, `hasCurrencySymbol`, `deriveUserFromRefAC`, `isUnbackedDatum`, `checkTxOutAtIndexWithDatumMinValueAndAddress`, `checkTxOutAtIndexWithDatumValueAndAddress`, `applyOracleAdminAction`, `SetAdmin`, `txBuildingExceptionToHttpStatus`, `interactionToTxSkeleton`, `interactionToTxBody`, `projectChainEvent`, `putMatchAndProjections`, `upsertByUnique`, `deployReferenceScripts`, `generateRefAndUserTN`, `nameFromTxOutRef`, `mkUntypedLambda`, `basicAuthServerContext`, `getBasicAuthFromEnv`, `runQuery`, `wipeChainSyncTablesRaw`, `rollbackTo`, `feeFor`, `checkFee`, `mkServiceProbeApp`, `evaluateChainSyncState`, `decodeConfigEnvOrFile`, `getPortFromEnvOrDefault` | yes | — |

### E. On-chain scripts: parameterisation and lambda size (backs DC-23, DC-26)

| Script | Compile signature | Parameter | Lambda span (lines) / non-comment |
|---|---|---|---|
| `MintingPolicy` | `mintingPolicyCompile :: ProtocolParams -> CompiledCode …` (`:424`) | 3 validator hashes + oracle token (`Types.hs:24-33`) | 31 + handlers 59 / 67 / 49 |
| `OracleNFTPolicy` | `oracleNFTPolicyCompile :: TxOutRef -> …` (`:57`) | seed UTxO; inlined, never a reference script | 10 |
| `ProfilesValidator` | `profilesCompile :: CompiledCode …` (`:172`) | none | 58 / 26 |
| `AttestationsValidator` | `attestationsCompile` (`:160`) | none | 66 / 36 |
| `DisputesValidator` | `disputesCompile` (`:199`) | none | **104 / 44** |
| `OracleValidator` | `oracleCompile` (`:126`) | none | 44 / 24 |

### F. Route cross-check (smoke doc vs generated Swagger)

- `docs/deployment/attest-flow-smoke.md` names `/claim-profile`, `/issue-attestation`, `/accept-attestation`, `/open-dispute`, `/resolve-dispute`, `/submit-tx`, `/status`, `/ready`. `interaction-swagger-api.json` documents all of them plus `/build-tx`, `/update-profile`, `/tx-status/{txId}`, `/health` — **12 paths, consistent** (`interaction-api/RestAPI.hs` ServiceAPI route literals: `claim-profile update-profile issue-attestation accept-attestation open-dispute resolve-dispute`).
- `query-swagger-api.json` has 29 paths; `scripts/check_swagger.sh:50-55` asserts the count and 22 names — consistent with `RestAPI.hs:1653-1682`.
- Enum spellings are consistent across both documents (`AttestationType`, `ProfileType`, `DisputeVerdict`), and `scripts/check_vocabulary.sh` globs both. Residual contradictions are the `GYAddress` prose (DC-33), the licence (DC-35) and the `GYAssetClass` prose (DC-36).

### G. One-line re-verification commands (run from the repo root)

```bash
# DC-01: no Query.Metrics module; matview is a second implementation
find src -name 'Metrics.hs'; sed -n 28,32p sql/030_metrics.sql
# DC-43: the spec and the superpowers tree are absent
ls docs; grep -rn 'spec' src/lib/onchain-lib --include='*.hs' | grep -c '§'
# DC-17/18: no auth/provider in QueryAppContext, no rate limiting anywhere
sed -n 30,48p src/exe/query-api/QueryAppMonad.hs; grep -rni 'rate.\?limit' src compose.yaml .github
# DC-40 / PG-02: compose services and the write profile's env
grep -nE '^  [a-z-]+:$|BASIC_|env_file|operation.prv' compose.yaml
# DC-03..07: the real env-var set
grep -rn 'lookupEnv "' src --include='*.hs'
# DC-28: SQL object counts
grep -hoE 'CREATE (MATERIALIZED )?VIEW|CREATE FUNCTION' sql/*.sql | sort | uniq -c
# DC-35: the licence string
grep -n 'license ?~' src/exe/*/RestAPI.hs
# DC-14: Id.hs has no callers
grep -rn 'deriveSeededId\|deriveIndexedId' src --include='*.hs' | grep -v 'Protocol/Id.hs'
# RL-4: no subject-kind on the attestation row
sed -n 1784,1800p src/lib/offchain-lib/Palmares/DomainTypes/Transfer/QueryResponses.hs
```

## 9. Not verified (static review limits)

- Nothing was built or executed: no `cabal build/test`, no Swagger/blueprint regeneration, no `docker compose`. Claims about *behaviour* (e.g. that `interaction-api` dies without `BASIC_*` under compose) are read from the code paths cited, not observed.
- Whether the spec, the F1 checklist, the D-/F-/T- registers and `docs/superpowers/*` exist privately: only their absence from this repository is asserted.
- ADR 0001's measurements, the Kupo probe numbers in `compose.yaml`, and the "owner decision" attributions in commit messages were taken at face value.
- The cluster manifests repository (`apps-k8s-configs`) and the `gov.cardano.vip` deployment were not inspected.
- Line numbers are from HEAD `4eb9117`; the parallel engineer's edits may shift them.
