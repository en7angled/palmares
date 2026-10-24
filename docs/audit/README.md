# Palmares — audit of the implementation as of 2026-10-22

**Target:** `main` @ `4eb9117` ("refactor(onchain): one trace code per mistake, and K2's first behavioural
test"), 94 commits, three days after the extraction from the Decentralized Belt System.
**Method:** six independent static reviews run in parallel, each confined to one layer and one output
file, followed by this synthesis. Nothing was built, tested or deployed: the machine the review ran on
has no Haskell toolchain, no PostgreSQL and no Docker daemon in use, so every claim below comes from
reading the code, the SQL, the workflows and the configuration, and is cited as `path:line`. Line numbers
drift with every commit; the IDs (`OC-`, `OF-`, `CS-`, `GV-`, `TD-`, `DC-`/`PG-`) are stable.

Severities are the reviewers'. Findings that the synthesis re-verified by hand are marked ✔ in §6.
Where a reviewer could not settle a question offline it is marked **VERIFY** in the report and listed in
§6; treat those as questions, not conclusions.

**Drift:** `main` advanced eight commits past the snapshot (to `5d50895`) before this branch was published.
§9 maps each of those commits to the findings and sections it touches; read §9 before acting on §3.

## 1. Executive summary

The on-chain layer is small and conservative, and the reviewers found **no way for a third party to
forge, hide or delete a record** — the product's central promise holds in the validators. Every mint
constrains the whole minted value, every state transition computes the expected datum on chain, every
spend authenticates its input by the NFT its datum names, and the oracle is found by a token recorded in
the datum rather than by address. The governance read path is a genuine views-only layer over db-sync
(0.01 % of the database), and the repository carries an unusual amount of self-review.

What needs attention falls into four groups, in order of urgency:

1. **Design decisions that freeze at first deployment.** The datum formats and the minting-policy
   parameter cannot change afterwards. Five on-chain items should be decided *before* preprod is
   treated as real: a single-key oracle admin (`OC-01`), authority tokens lockable into state outputs
   on four paths (`OC-03`), an un-pausable `AcceptAttestation` (`OC-02`), a claimed credential that
   loses its CIP-129 role so a committee cold key is published as a DRep id (`OC-04`, `OF-16`), and
   untyped ids that let a dispute target a profile and let an issuer attest itself (`OC-05`). None is
   a forgery vector; all are cheap now and impossible later. Add the absent upgrade story (`OC-09`)
   and the spendable reference-script UTxOs (`OF-08`).
2. **The attestation path is not operable as shipped.** Admin rotation cannot be completed with the
   CLI because the incoming admin's signature is required and never collected (`OF-01`); the default
   `deposit_to` breaks `Md8` for multi-address wallets (`OF-02`); a hostile `attestationPeriod` sends
   the projector into a permanent crash loop (`CS-01`); fork detection is slot-only (`CS-02`);
   `compose.yaml` has no `attest-sync` service and its `write` profile cannot boot (`TD-02`, `CS-03`,
   `DC-40`).
3. **Trust claims the code does not yet honour.** The served DRep numbers are not produced by the SQL
   published at `/metrics/formulas` (`GV-03`, `DC-01`); the Koios nightly is broken by the `unknown`
   status and a stale fixture keeps it green (`GV-02`); the documented deployment runs the public API as
   the database superuser (`GV-04`) and rebuilds the schema with `DROP SCHEMA … CASCADE` on every boot
   (`GV-01`); a local image build bakes the provider token into the image (`TD-01`); the spec the code
   cites in thirteen places is not in the repository (`DC-43`).
4. **Hygiene with real cost.** Twenty-two trace codes, including the two security fixes made on
   2026-10-22, have no validator-level test (`TD-04`); three query modules and one on-chain module are
   dead but still referenced by the `CLAUDE.md` files; README §11 misdescribes the environment; a CI
   cache defeats the "fresh checkout" assumption the trace-code work relied on (`TD-03`).

## 2. Headline numbers

| Report | Scope | Critical | High | Medium | Low | Info | Total |
|---|---|---|---|---|---|---|---|---|
| [01 On-chain security](01-onchain-security.md) | the six Plutus scripts, CIP-68, Utils, Blueprint | 0 | 1 | 5 | 4 | 5 | 15 |
| [02 Off-chain and write API](02-offchain-and-write-api.md) | TxBuilding, domain types, interaction-api, admin CLI, webapi-lib | 0 | 2 | 12 | 9 | 2 | 25 |
| [03 Chain-sync and projections](03-chainsync-and-projections.md) | Kupo client, attest-sync, Ingestion, Storage, attestation reads | 1 | 2 | 7 | 7 | 1 | 18 |
| [04 Governance read path](04-governance-read-path.md) | SQL views, metrics, query-api, Koios reconcile | 0 | 4 | 13 | 8 | 0 | 25 |
| [05 Tests, CI and delivery](05-tests-ci-and-delivery.md) | test suite, workflows, images, compose, scripts, secrets | 0 | 3 | 9 | 7 | 1 | 20 |
| [06 Docs, spec and product gaps](06-docs-spec-and-product-gaps.md) | every claim in the docs vs the code; promises vs delivery | — | 11 | 15 | 17 | — | 43 doc items + 16 product gaps |

Report 05 also carries a 63-row table mapping every on-chain trace code to the test that exercises it,
and report 06 a table of every environment variable the code reads against README §11.

## 3. Do-first list

Ranked by impact on the product's promise and by how much harder each item becomes after the first
deployment. Effort is the reviewer's estimate (S < 1 day, M = days, L = a week or more).

__THIS IS THE LIST THAT IS KEPT CURRENT.__ Reports 01-06 are a dated snapshot against `4eb9117` and
report 07 is one against `2bf5bde`; editing either would destroy what makes them worth keeping, which
is that they record what was seen on a given day. So the `Status` column lives here and nowhere else
— twenty-two rows updated per closure, rather than a 189-row verdict table nobody reads twice.

| # | ID | Sev. | Effort | Action | Why now | Status |
|---|---|---|---|---|---|---|
| 1 | OC-01 | High | S/M | `opAdminPkh :: PubKeyHash` → `opAdmin :: Credential`, proved with the same rule as `checkCredentialControl` at `O1`, `O5`, `D1`; multisig admin tooling | datum format freezes at deployment; key loss today freezes the protocol and every open deposit | **CLOSED** `93e12ac` — ADR 0005 |
| 2 | OF-01 | High | M | two-step `rotate-admin`: build → `sign-tx` by the incoming admin → submit | rotation is impossible with the shipped CLI, so the single key cannot even be rotated | **CLOSED** `93e12ac` — ADR 0005 |
| 3 | CS-01 | Critical | M | clamp datum-sourced timestamps before `timestamptz`; isolate each match's projection (dead-letter row); add the 10^20 period test | one hand-built attestation halts the projector permanently and the cursor never advances | **CLOSED** — boundary clamp `8be51d9`, per-match isolation + `attest_dead_letter` (schema v5) |
| 4 | OC-03 | Medium | S | add "user token quantity == 0" to `P5`, `Mk`, `A1`, `Md5` (the `Mp6` rule on the other four output checks) | closes a self-inflicted lock-in that makes a profile world-writable and impersonable | **CLOSED** — `Pa`/`Ms`/`A8`/`Md9`, +243 bytes, 4 pure pairs |
| 5 | OF-02 | High | S–M | default `deposit_to` to the address holding the user NFT; force an input from it; 400 otherwise | `Md8` rejects multi-address wallets and the error reads "Not enough ADA" | **CLOSED** — default is the user-NFT address, named ones forced as inputs or 400, swagger 3.2.0 |
| 6 | OC-02 | Medium | S | `attestationOracleToken` field + `A7` pause gate on `AcceptAttestation`, or document the exception | the irreversible write is the one that is not pausable; format freezes at deployment | **CLOSED** — `A7` + `attestationOracleToken` |
| 7 | OC-04 / OF-16 | Medium | S/M | role-tagged `ClaimedCredential`; render with the right CIP-129 prefix; refuse `cc_hot` | a committee cold key claim is currently published as `drep1…` | **CLOSED** — ADR 0006 |
| 8 | OC-05 | Medium | M | per-kind CIP-67 labels so `Mg`/`Md4` can type an id; `subject /= issuer`; decide lineage | disputes can target profiles, issuers can attest themselves; label choice freezes at deployment | **CLOSED** — labels 1/2 private-use, `Mg`/`Md4` typed, `Mr` added, lineage dropped |
| 9 | OF-08 | Medium | S | lock reference scripts at an always-fail address; verify their hashes in `/ready` | today the operator (or a compromised key) can spend them and every protocol tx stops building | **CLOSED** — deployed to Atlas's limbo validator (min-ADA now spent, not parked); readiness checks compiled = configured = on-chain hash, and the deploy verifies itself before writing the config |
| 10 | GV-01 | High | M | hash-gated bootstrap + advisory lock + schema swap (or `WITH NO DATA` then refresh) | `DROP SCHEMA palmares CASCADE` on every boot is a read outage per restart with >1 replica | **CLOSED** — md5 fingerprint gate + `pg_advisory_xact_lock`; an unchanged restart does no DDL |
| 11 | GV-04 / CS-03 / TD-02 / TD-09 | High | S–M | compose: add `attest-sync`, require `BASIC_USER`/`BASIC_PASS`, run `apply-roles`, use `palmares_ro`/`palmares_owner` DSNs, bind ports to `127.0.0.1`; `PG_CONN_STR` fail-closed | the documented self-host path runs as superuser and cannot serve attestations | **CLOSED** — `attest-sync` + `palmares-roles` added, reads as `palmares_owner`, ports on 127.0.0.1, `BASIC_*` required, `PG_CONN_STR` fail-closed |
| 12 | TD-01 | High | S | `.dockerignore` `config/config_atlas.json` and the validators config; stop `COPY config` into runtime images | a local `scripts/build-images.sh` ships the Maestro token; ADR 0002 claims the opposite | **CLOSED** — both configs out of the build context, four runtime `COPY ./config` removed, and the build script refuses without the exclusions |
| 13 | GV-02 | High | S | fetch `/dreps` without the status filter; re-record the snapshot pair; assert status coverage | the nightly parity gate reports 90 false divergences and the fixture hides it | **CLOSED (live half)** — the reconciler sends no status filter, so it rides the API default. Re-recording the stale snapshot needs live Koios: BLOCKED-ON-USER, command in `koios-parity-gate.md` |
| 14 | GV-03 / DC-01 | High | M | one source for the six formulas (generate the matview from the catalog, or publish the matview as the formula); run the 070 agreement in CI | "the SQL you see is the SQL that runs" is the README's first promise and is not true today | **CLOSED** in shape (a)+(b), and the drift it predicted was already real: the matview's `eligible_actions` counted vote ROWS (23 of 809 preprod DReps inflated, one served rate 0.2452 against the formula's 0.5846). Fixed; `UnitTests.MetricAgreement` compares the SERVED response against all five formulas for every DRep in a seeded corpus with a re-vote in it; 070 widened to assert the denominator for every DRep (736 ms); the four prose claims rewritten, swagger 1.3.1. Single-source NOT taken — see the ledger for why |
| 15 | CS-02 / CS-04 | High | M | verify the cursor's block hash via `/checkpoints/{slot}` each tick, walk back to the common point; treat `spent_at` above the rollback slot as unspent on replay | short forks leave orphaned projections in place | **CLOSED** — `verifyCursor` runs every tick before the slot comparison is trusted; Kupo's non-strict answer IS the newest surviving ancestor (measured against v2.12.0), so one call both detects the orphan and names the rollback target, with the margin kept as the fallback. `rollbackTo` clears a `spent_at` above the rollback slot in the stored snapshot and in the replay. 9 tests; the CS-04 pair fails on the old code with "no row at all" |
| 16 | OC-09 | Low | M/L | decide the upgrade stance now (`protocolVersion` field, multi-policy chain-sync, or "a fix is a new registry") | the first validator fix after deployment has no path | **CLOSED** — ADR 0007: stance (a) written, the policy-change WIPE removed, history column |
| 17 | TD-04 | Medium | M | pure valid/broken pairs for `Mp6`, `O6`, `P2`, `P5`, `N0`, `K3`, `Mg` | two security fixes from 2026-10-22 shipped untested, against the test rules | **CLOSED** — six pairs in `MutationGuards` (8.23–8.28), and the mutation run that justifies them: all six conjuncts deleted at once turns every pair `(True, True)`, so each is refused by the code it names and nothing else. `K3` does not exist — it was retired with the three callerless lookups. The report's other two "that matter", `U2`/`U3`, are **unreachable**: their only two functions have no caller anywhere in `src/`, so they are dead code, not a coverage hole (flagged, not deleted) |
| 18 | OF-03 / OF-04 | Medium | S | pause guard in `resolveDisputeTX`; `getFeeSkeleton` returns `mempty` when `feeFor … <= 0` | disputers currently pay a hidden min-ADA "fee" when fees are configured | **CLOSED** — pause guard was one line (the builder already had the flag); zero price now emits no output |
| 19 | TD-03 | High | S | stop caching `dist-newstyle` (or key it on `palmares.cabal` and the plugin flags) | `ghc-options` changes do not reliably recompile; CI is no longer the fresh checkout the trace-code commit assumed | **CLOSED** — two cache entries: the store keeps loose restore-keys, `dist-newstyle` is keyed on `palmares.cabal` with none |
| 20 | DC-43 | High | S | commit `docs/spec/` (the spec cited as §2/§3/§4.1/§4.3/§6) and resolve or delete the D-/F-/T- ids | the protocol's requirements are not reviewable from the repository | **CLOSED** — `docs/spec/{protocol,metrics,decisions}.md` + a README. The spec is translated with its numbering frozen, so every `§N` citation resolves; where a later ADR superseded a line the original stays with a `[Superseded: …]` note. All 15 `D-` and 11 `F-` ids cited in the repo have a row. The 8 catalog `spec` fields now point at `docs/spec/metrics.md#<formula_id>` (swagger/metrics doc regenerated); the last `docs/superpowers/` pointer in `config/` is gone |
| 21 | CS-07 / GV-23 | Medium | M | `palmares_attest.sync_state`; `/status.attestation`; `X-Attest-*` headers; red on absence | `/ready` now sees attestation freshness, `/status` and the headers do not | open |
| 22 | OF-05 | Medium | M | distinct error codes for script failure / shortfall / provider / await; catch `SomeException` at the handler | every build failure is `400 InsufficientFunds`; some provider errors are bare 500s | open |

The full ranked backlogs (103 code findings, 43 documentation items, 16 product gaps) are at the end of
each report.

## 4. Cross-cutting themes

- **Pre-deployment is the cheap moment.** Seven of the top ten items change a datum, a redeemer or a
  parameter. The repository already treats constructor indices as a deployed-data contract; the same
  discipline should gate the first preprod deployment on the decisions in items 1, 4, 6, 7, 8, 16.
- **The oracle admin is the protocol's availability.** `O1`/`D1` pin one key; the deposit-return path
  (`D4`) and the pause lever depend on that key being live and honest, and the tooling cannot rotate it
  (`OF-01`). A native-script admin plus a working two-signature rotation is the single highest-leverage
  change.
- **Convention is not enforcement in the deployment.** Role separation, the attest-sync service, auth
  for the write path, port exposure and the exclusion of secrets from images all exist in prose and are
  absent or wrong in `compose.yaml`, `.dockerignore` and the Dockerfiles (`GV-04`, `CS-03`, `TD-01`,
  `TD-02`, `TD-09`, `DC-40`).
- **The read layer owes the chain several promises.** The on-chain comments delegate presentation rules
  to the read layer: `unclaimed` vs verified (PASS), claimed period labelled as claimed (PASS), disputes
  shown beside the record (PARTIAL — list rows carry no "contested" marker), lineage attestations not
  shown as pending (FAIL), several claimants of one credential (PARTIAL). Report 06 §2 and `CS-13`.
- **Two implementations of the same arithmetic.** The matview and the catalog SQL (`GV-03`), the
  on-chain and off-chain pause/fee/dust rules (`OF-03`, `OF-04`, `OF-20`), and the `/ready` vs `/status`
  freshness views (`CS-07`) each pair a rule with a copy that can drift. Where the repository already
  pins pairs with property tests, extend that; where it cannot, delete the copy.
- **Documentation debt is concentrated, not diffuse.** The root and per-library `CLAUDE.md` files point
  at modules that are not compiled (`Query/Projected.hs`, `Pages.hs`, `Aggregates.hs`, a `Query.Metrics`
  that never existed, `Protocol/Id.hs` with zero callers), README §11 has five wrong rows and eleven
  missing names, ADR 0001 says fourteen views where there are nineteen, and the interaction Swagger
  declares GPL-3.0. Report 06 §7.1 lists the exact edits.
- **Coverage is good where it was deliberate and absent where it was recent.** Inherited fixes #1–#5
  each have a test that fails on the old behaviour; `failedWithTrace` really matches the code; but 22
  of 63 trace codes have no validator-level test, privnet and balance checks are unused, and the
  determinism job runs on zero rows (`TD-04`, `TD-20`, `GV-25`, `CS-17`).

## 5. Per-report summaries

**01 — On-chain security.** No Critical; nothing lets a third party forge, hide or delete a record.
The 14-rule checklist from `src/lib/onchain-lib/CLAUDE.md` is applied per script and the sixteen
hypotheses the orchestrator posed are each confirmed or refuted with evidence. Top: single-key admin
(`OC-01`), authority-token lock-in on four `geq` paths (`OC-03`), un-pausable acceptance (`OC-02`),
credential role lost (`OC-04`), untyped ids (`OC-05`). Also: deposits depend on admin liveness and two
`depositTo` shapes lose the deposit (`OC-06`), `Cleanup` hands a mis-sent user token to any sweeper
(`OC-07`), `ProtocolParams` in every profile datum is ~0.4 ADA of dead weight (`OC-08`), no migration
path (`OC-09`), dead code and stale prose (`OC-11`).

**02 — Off-chain and write API.** Output layouts match the redeemer indices on every path (verified
per operation). Top: `rotate-admin` cannot satisfy `O5` (`OF-01`), `deposit_to` default vs `Md8`
(`OF-02`), error translation collapses everything into `400 InsufficientFunds` (`OF-05`), zero-priced
actions still emit a fee output (`OF-04`), `resolveDisputeTX` ignores the pause (`OF-03`). Also:
`/submit-tx` is an open relay (`OF-07`), reference scripts sit at a spendable key address (`OF-08`),
`sign-tx` signs anything with the admin key (`OF-09`), lookups trust any asset class so a parked dispute
datum blocks `open-dispute` (`OF-10`), script-credential claims drain the spent script UTxO to the
claimant (`OF-11`), the bech32-vs-hex Swagger text is the project's own (`OF-15`).

**03 — Chain-sync and projections.** Top: hostile `attestationPeriod` crash loop (`CS-01`), slot-only
fork detection (`CS-02`), not deployable as documented (`CS-03`), replay trusts stale `spent_at`
(`CS-04`), loop crashes on any non-Kupo exception while the probe stays green (`CS-05`). Also: the
policy-mismatch wipe is unguarded (`CS-06`), freshness is on `/ready` but not on the wire (`CS-07`), Kupo
drift (`--since`, pruning, network) is undetectable (`CS-08`), no single-writer guard (`CS-10`), the
raw-match log stores every wallet UTxO holding a user token (`CS-11`), `FETCH_BATCH_SIZE` defaults to
10,000,000 in code vs 100,000 documented and `BATCH_SIZE` is read by nothing (`CS-12`).

**04 — Governance read path.** Injection surface is clean (whitelisted sort keys, bound parameters,
real LIKE escaping, CSV guard). Top: boot DDL drops the schema (`GV-01`), Koios nightly broken by
`unknown` (`GV-02`), served numbers not from the published SQL (`GV-03`), superuser in the documented
deployment (`GV-04`), no rate limiting contrary to the docs (`GV-05`). Also: joins by `drep_raw` can fan
out on preprod's duplicated raw hashes (`GV-06`), the activity cursor is not total for multi-beneficiary
treasury enactments (`GV-07`), `/gov-actions` pages pay a per-row correlated vote count (`GV-10`), the
out-of-band indexes are load-bearing and unverified (`GV-17`), and eight ledger-semantics questions are
marked VERIFY (`GV-08`, `GV-12`, `GV-13`, `GV-14`, `GV-19` and the bootstrap-phase rules).

**05 — Tests, CI and delivery.** Positive: `failedWithTrace` matches code strings, inherited fixes #1–#5
each have a fails-on-old-behaviour test, history is clean of secrets. Top: provider config baked into
images (`TD-01`), compose cannot serve attestations and the `write` profile cannot boot (`TD-02`), the
`dist-newstyle` cache (`TD-03`), 22 untested trace codes (`TD-04`), three toolchains and an
unchecksummed libsodium (`TD-05`). Also: `check_vocabulary.sh` excludes five live test modules and hides a
banned word (`TD-06`), no alerting on nightly failure (`TD-07`), false compose claims about digest pinning
and amd64 (`TD-08`), ports on all interfaces with a default password (`TD-09`), unpinned downloads in CI
(`TD-10`), root images with build toolchains in layers (`TD-11`), no image ever built from a PR (`TD-12`).

**06 — Docs, spec and product gaps.** 43 documentation items (11 High) with the exact edit for each,
16 product gaps, and the six read-layer obligations graded. Top: the published-formula claim (`DC-01`),
the missing spec (`DC-43`), `src/exe/CLAUDE.md` misdescribing query-api security (`DC-17`/`DC-18`), the
stack that cannot run the attestation flow (`DC-40`/`DC-10`/`PG-02`), the self-contradicting write-path
story and the GPL-3.0 licence string in the interaction Swagger (`DC-02`/`DC-29`/`DC-35`). Product gaps:
no explorer/frontend in the repository, no mainnet provisioning, three admin commands missing, write path
needs a provider token, arm64-only images against an x86_64 mainnet host.

## 6. What the synthesis re-verified by hand, and what remains open

Re-verified directly in the files, independently of the reviewers ✔:

- `TD-01` — `.dockerignore` excludes `config/*.prv` but not `config/config_atlas.json`; all four service
  Dockerfiles `COPY config ./config` (builder) and `COPY ./config /app/config` (runtime).
- `TD-02` / `CS-03` / `DC-40` — `compose.yaml` defines `cardano-node`, `postgres`, `cardano-db-sync`,
  `kupo`, `interaction-api`, `query-api` and no `attest-sync`; no `BASIC_*` variable appears in it.
- `GV-01` — `sql/000_schema.sql` is `DROP SCHEMA IF EXISTS palmares CASCADE; CREATE SCHEMA palmares;`
  applied at every boot under a 10 s `lock_timeout` (`Query/Views.hs`).
- `GV-04` — `compose.yaml` gives query-api `PG_CONN_STR: host=postgres user=postgres …`.
- `CS-01` (mechanism) — `Storage.hs` stores `claimedPeriodFrom/To` as `Maybe GYTime`, `Conversions.hs`
  converts the datum's period without bounds, and `ChainSyncLogic.hs` retries only Kupo client errors.
- `OC-03` (reasoning) — `P5`/`A1` require output value ≥ own value and `P3`/`Mf` read `valueSpent`,
  which includes the script input; a user token once locked in the state output therefore satisfies the
  authority check for any later spender.
- The on-chain ER diagrams in `../architecture/onchain-protocol.md` — every field, constructor and
  index against `Protocol/Types.hs` and the validators.

Open questions the reviewers could not settle offline (each is marked VERIFY in its report):

- Conway ledger semantics behind the views: `expiration` vs `gasExpiresAfter` (`GV-12`),
  `ratified_epoch` boundary placement (`GV-08`), which `drep_distr` epoch a ratification weighs,
  bootstrap-phase vote rules at protocol major 9, `is_valid IS NULL` (`GV-13`),
  `reward_rest.spendable_epoch` (`GV-19`).
- Atlas behaviour: whether a 0-lovelace output is raised to min-ADA or fails the build (`OF-04`),
  whether `GYAwaitTxException` is a `GYTxMonadException` (`OF-05`), reference-input de-duplication,
  coin-selection treatment of reference-script UTxOs (`OF-08`).
- `plutus-ledger-api` 1.43.1.0 semantics (`mintValueMinted`, `geq`) were checked against `master`,
  not the pinned tag.
- Anything that needs a running stack: `sql/checks/*.sql` against preprod, the smoke scripts, the
  static link in `Dockerfile.base`, CI durations, branch protection, the out-of-repo Kubernetes
  manifests and the `gov.cardano.vip` deployment.

## 7. Suggested sequencing

1. **Decide before deploying** (one session with the owner): items 1, 4, 6, 7, 8, 16 of §3 and the
   eleven open questions in report 01 §8. Record each as an ADR (`DC-`: ADR hygiene, report 06 §4).
2. **Make the shipped stack true** (a day): items 11, 12, 19 and the compose/README/env fixes in
   report 06 §7.1 — so that `docker compose --profile write up` boots and serves attestations.
3. **Make the attestation path survive hostile input and forks** (days): items 3, 5, 15, 21 plus
   `CS-05`, `CS-06`, `CS-10`.
4. **Make the trust claims literal** (days): items 13, 14 and `GV-05` (either rate-limit or stop
   claiming it), then the read-layer obligations in report 06 §2.
5. **Close the test and documentation debt** continuously: item 17, the dead modules, the `CLAUDE.md`
   tables, the spec.

## 8. Reports

| File | Lines | Reviewer focus |
|---|---|---|
| [`01-onchain-security.md`](01-onchain-security.md) | 310 | Plutus validators against the 14-rule checklist and 16 targeted hypotheses |
| [`02-offchain-and-write-api.md`](02-offchain-and-write-api.md) | 602 | tx building, write HTTP API, admin CLI, 15 hypotheses verified one by one |
| [`03-chainsync-and-projections.md`](03-chainsync-and-projections.md) | 501 | Kupo → attest-sync → `palmares_attest` → reads; 14 hypotheses graded |
| [`04-governance-read-path.md`](04-governance-read-path.md) | 662 | SQL views, metrics, query-api, Koios parity; per-view semantics table |
| [`05-tests-ci-and-delivery.md`](05-tests-ci-and-delivery.md) | 709 | trace-code coverage map, CI, images, compose, scripts, secrets |
| [`06-docs-spec-and-product-gaps.md`](06-docs-spec-and-product-gaps.md) | 425 | claim-by-claim doc check, read-layer obligations, product gaps, ADR hygiene, licensing |
| [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md) | 1032 | every finding re-judged against `2bf5bde`, with a toolchain, a database and web access the original pass did not have |

Architecture documentation written alongside these reports: [`../architecture/README.md`](../architecture/README.md).

## 9. Drift since the snapshot (added 2026-10-23)

`main` advanced eight commits from the snapshot `4eb9117` to `5d50895` (2026-10-22/23) while these reports
were being written. None of them touches `docs/audit/` or `docs/architecture/`, and this branch is based on
`5d50895`, so the code beside these documents is newer than the code they cite; every `path:line` is still
from `4eb9117`. Files changed upstream: `.github/workflows/ci.yml`, `CLAUDE.md`,
`src/lib/onchain-lib/CLAUDE.md`, `palmares.cabal`, `docs/generated/swagger/query-swagger-api.json`,
`scripts/{check_roles,check_swagger,smoke_attest_flow}.sh`, `sql/050_roles.sql`, `src/exe/admin/Main.hs`,
`src/exe/query-api/{RestAPI.hs,Query/Gov.hs,Query/ServiceStatus.hs}`,
`src/lib/offchain-lib/Palmares/{Ingestion.hs,Reconcile/Koios.hs,TxBuilding/Operations.hs,DomainTypes/Transfer/QueryResponses.hs}`,
`src/lib/onchain-lib/Palmares/Onchain/{CIP68.hs,Protocol.hs,Utils.hs,Protocol/Lookup.hs}` plus
`Protocol/Id.hs` **deleted**, `src/lib/webapi-lib/Palmares/WebAPI/Envelope.hs`,
`src/test/UnitTests/{GovDto,WritePath}.hs`. Findings that cite other files are unaffected. Findings that cite
these files keep their substance unless the table below says otherwise, but their line numbers have moved.

| Upstream commit | What it does | Findings and sections to re-judge |
|---|---|---|
| `39365fe` feat(admin) | `admin operator-address` now also prints the CIP-129 DRep id of the operator key (three forms from one derivation); three tests in `UnitTests.WritePath`. | Report 06 CLI table row `operator-address` ("bech32 and raw hex" is now three forms); `onchain-flows.md` §1 bootstrap sequence and CLI table say two. OC-04 / OF-16 are **not** addressed: the id is rendered through `claimCredentialToText`, the very function OF-16 is about. |
| `9a8d79b` feat(query-api) | `/status` gains `attest_lag_seconds` (nullable, its own field, not inside `SyncStatus`); Swagger `1.0.0` → `1.1.0`; `check_swagger.sh` gains two checks. | CS-07 ("on the probe but not on the wire; absence is silent"): largely addressed, re-judge. GV-23 (`/status` under-reports): partly. DC-37 (version census): the query-api document is now `1.1.0`; the four-way inconsistency remains. |
| `45784f7` test(smoke) | `smoke_attest_flow.sh` preflight refuses a non-`drep1y` id and a `null` `attest_lag_seconds`; a stale comment corrected. | Report 05 scripts table row for `smoke_attest_flow.sh`; DC-34 citations into `docs/deployment/attest-flow-smoke.md` may have shifted. |
| `3654f57` refactor(onchain) | Deletes `Protocol/Id.hs` (`deriveSeededId`, `deriveIndexedId`), `unsafeGetProfile`, `unsafeGetProfileDatumAndValue`, `unsafeGetProtocolParamsFromProfileRefInput` (and with it trace code `K3`), the exact-value pair `checkTxOutAtIndexWithDatumValueAndAddress` / `isTxOutAtIndexWithDatumValueAndAddress`, `hasTxInAtAddressWithNFT`, `updateCIP68DatumImage`, `validateImageURI`, off-chain `hasUserNFTAt`; re-attaches the `isUnbackedDatum` Haddock; fixes the CLAUDE.md pointers. Script sizes byte-identical. | OC-11: most of it done, verify and close. DC-14, DC-25, the zero-callers rows of report 06's dead-code table: resolved. OF-19 (`hasUserNFTAt`, `Id.hs`): the dead-code half resolved. TD-04 and §3 row 17 above: drop `K3` from the list of codes needing a pure pair (counts in TD-04 shift by one; the coverage table in report 05 loses its `K3` row). `onchain-protocol.md` §1 module table and §8 inventory (now 64 codes, `K1`–`K2`); `system-overview.md` §3.1 on-chain node and module-index row for `Protocol.Id`. **One claim in that commit is false and deserves a finding:** its new Haddock (`Lookup.hs:7` at `5d50895`) says every validator reads a profile "through `Utils.checkAndGetCurrentStateDatumAndValue` directly"; `git grep checkAndGetCurrentStateDatumAndValue 5d50895 -- src` finds no caller outside comments, so that helper is now dead and `U2` stays unreachable, exactly as `onchain-protocol.md` §8 says. |
| `5978d28` fix(query-api) | `/ready` now adds the projector's lag to db-sync's lag before comparing with the ceiling; `null` for `attest_lag_seconds` documented as three causes; `drep1y` check tightened to CIP-129 length (58 chars); DRep id printed before the config `die`; two cancelling tests replaced by one along the production path. | CS-07, GV-23: re-judge together with `9a8d79b`. CS-05 ("green probe while stuck"): the probe arithmetic changed, re-read. OF-16: the length check is stricter but the role is still dropped, still open. Report 03 §CS-07 "what the code does" (`attestLag = dbsync_tip_slot − chain_cursor.slot_no`): re-read against the new `/ready` arithmetic. |
| `a9bfd71` chore | `-Wall` census: `Ingestion.hs` `scriptAddress` renamed `validatorAddress`; unused imports dropped; `http-types` and `wai-extra` removed from `interaction-api`, `warp` from the test suite; `plutus-tx-plugin` deliberately kept. | OF-13 (no body-size limit) cited `wai-extra` as already a dependency; the recommendation stands, the dependency must be re-added. Report 05 notes on `-Wunused-packages`: acted on. `system-overview.md` §3.1 dependency edges: re-derive from `palmares.cabal`. |
| `307b534` fix(admin) | `executeCommand` enumerates `NewOperatorKey`, `OperatorAddress`, `SignTx` (an unreachable non-exhaustive-pattern crash becomes a compile-time check); `from`/`to` shadowing renamed. | OF-22 (admin CLI rough edges): check whether this was one of its bullets. |
| `5d50895` fix(sql) | `050_roles.sql`: `ALTER DEFAULT PRIVILEGES … IN SCHEMA palmares_attest` loses `FOR ROLE palmares_owner`, so the grant now covers tables created by the connecting role; `check_roles.sh` asserts it; CI's determinism job applies the file and creates the table in the order that used to lose the grant; smoke preflight points at `check_roles.sh`. | CS-03: the grant half is fixed; the compose-service and `palmares_owner`-DSN halves are not (`compose.yaml` unchanged upstream). GV-04: unchanged (`user=postgres` in compose). TD-20 and the CI diagram in `system-overview.md` §9.5: the determinism job has new steps. The roles table in `system-overview.md` cites `050_roles.sql:57-92`; lines moved. DC-30: unchanged. |

Four of the eight commits land on items this audit also raised (OC-11, OF-19, DC-14, the grant half of CS-03).
Treat the overlap as corroboration of those items, not as evidence that the rest of the list has been read.

## 10. Reconciliation against `2bf5bde` (2026-10-23)

`main` advanced another six commits past §9's table, to `2bf5bde`. Every finding in all six reports has
been re-judged against the code as it stands; the per-finding verdicts, with evidence from `2bf5bde`
rather than from the snapshot, are in [`07-reconciliation-2026-10-23.md`](07-reconciliation-2026-10-23.md).

**The audit held.** Of 189 rows judged, **163 are still open**, 17 are partly closed, **3 are fixed** and
**4 were wrong when written**. The fourteen commits since the snapshot were on-chain design decisions, a
warning sweep and tests — `.dockerignore`, `compose.yaml`, the `Dockerfile.*` files, `README.md`,
`.env.example`, `NOTICE`, both ADRs and both deployment documents are **byte-identical to `4eb9117`**, so
those findings keep their line numbers exactly as published.

### What is closed

| Finding | By | Evidence |
|---|---|---|
| `OC-02` un-pausable acceptance | `26d53f7` (decision D-C) | `attestationOracleToken` at `Protocol/Types.hs:445`; `A7` as the **first** conjunct at `AttestationsValidator.hs:139` — the fix this report prescribed, taken as prescribed. Its cost estimate was out by 5×: "~100 script bytes" against a measured **+494**, because `A7` brought this validator's first oracle read |
| `OC-06` (1) deposits depend on admin liveness | `26d53f7` (decision D-A) | `ExpireDispute` at `DisputesValidator.hs:195-201`, `D9`, `disputeStaleAfter` at `Types.hs:556`. Anyone may close a stale dispute after the deadline, with no key and no oracle read. The owner chose "anyone" over "the opener"; the shapes (2)(3)(4) that lose the deposit are CLOSED too as of 2026-10-24: `Mda` requires the refund address to be a key address, +29 bytes for all three, and the off-chain builder refuses a script `deposit_to` as `DepositAddressIsScript` before the signature |
| `OC-11` a, b, and most of c | `3654f57` | `Protocol/Id.hs`, `unsafeGetProfile*`, `K3` and four dead helpers are gone |

`CS-03`'s grant half (`5d50895`) and `CS-07`/`GV-23`'s wire half (`9a8d79b`, `5978d28`) were already
recorded in §9 and are confirmed. **`OC-01`'s severity argument loses one clause**: key loss no longer
locks every open deposit forever, because `ExpireDispute` needs no key. The finding stands on pause,
fees, verdicts and rotation.

### What was wrong

Four findings, all in report 04, all ledger-semantics questions the reviewers marked **VERIFY** and
then wrote up as findings anyway:

- **`GV-08`** — `ratified_epoch` is the epoch db-sync *determined* ratification in, not the epoch whose
  votes counted. Arm 7's placement is correct and the proposed fix would move it a full epoch late.
- **`GV-13`** — `is_valid IS NULL` means the body is **not valid JSON at all**, not "not checked", so
  `invalid_schema` is defensible. The repository's own comment is the error, not the mapping.
- **`GV-19`** — `spendable_epoch` and `enacted_epoch` are written from one value, two lines apart in one
  loop; the `earned_epoch = spendable_epoch - 1` the finding reasons from is a generated column db-sync
  never writes.
- **`GV-25`**, one bullet of three — `checks/030_votes.sql:95,98,104-112` does cover `palmares.thresholds`.

Three further items are not wrong but **unusable as written**, and a reader should not apply them
verbatim: `OC-03` and `OC-07` prescribe trace codes `P8`/`P9`, which ADR 0003 burnt; `OC-05` prescribes
`subject /= issuer` globally, where `Mc1` now requires the opposite for two of the seven kinds; `OF-16`
prescribes deriving the credential's role from `profileKind`, which is unreachable now that the
credential lives on an attestation and an attestation has no kind of profile. `TD-08`'s arithmetic is
wrong in its own terms (three of six images are digest-pinned, not five of seven) and `TD-10` lists
`ci.yml` for pins that live in `images.yml`.

### The VERIFY list is closed

All eight ledger-semantics questions in §6 are settled with citations (report 04 §VERIFY), four of the
five Atlas questions are settled against the pinned 0.14.1 source (report 02): a 0-lovelace fee output
**is** raised to min-ADA by `adjustTxOut`, so `OF-04`'s hidden fee is real; `GYAwaitTxException` **is** a
standalone newtype, so `OF-05`'s gap is real; coin selection **does** exclude reference-script UTxOs, so
`OF-08` holds only in the shape the report hedged. `GV-03`/`DC-01` is settled with exact arithmetic: the
matview counts `count(*)` after a `LEFT JOIN` to every vote **row**, so the served participation rate is
`V/(E+X)` where the published SQL says `V/E`, and the repository's own check file measures `X ≥ 69`
today. The one question still open is the pinned `plutus-ledger-api` 1.43.1.0 source, which is not on
this machine — CHaP carries only the index entry. The behaviour is pinned empirically by the mint tests
instead, which is better evidence than reading the library.

### Thirty-nine new findings, and where they came from

The reconciliation raised 39 findings the audit does not contain. They split in two, and the split is
the useful part:

- **Introduced by the six commits since §9** — most of them by ADR 0003, which changed four datums, two
  redeemers and the HTTP surface while `Blueprint.hs` took a **zero-byte diff**. Two smoke scripts were
  left asserting a world that no longer exists (`smoke_interaction_api.sh` on version `3.0.0` and 12
  paths; `smoke_attest_flow.sh` still POSTing `credential` and `witness` to `/claim-profile`), the
  published blueprint described two of three mint redeemers and omitted `ExpireDispute` entirely, and
  `attestation_credential` was stored and served nowhere. The sharpest is **`NEW-CS-1`**: the derived
  `profile_credential` column was order-dependent in a way a replay breaks, and `currentSchemaVersion`
  3 → 4 makes that replay the upgrade path for every existing database.
- **Missed by the original pass** — `NEW-OC-5`/`NEW-TD-1` (the `Lookup.hs:7` Haddock asserts a call that
  does not exist, so `U2`/`U3` sit in unreachable code), `NEW-TD-2` (`O6`'s predicate had no test at any
  level), `NEW-OF-5` and `NEW-DC-*` for several stale sentences that pre-date the snapshot, and
  `NEW-GV-1`/`NEW-GV-6`, which are the findings `GV-03` and `GV-08` were reaching for.

### What was fixed in response

Seven of the new findings were closed in the same pass, chosen because they are defects in the last
day's own commits and because three of them move script hashes, which is free only while nothing is
deployed:

- `NEW-OC-1` — `oracleParamsAreWellFormed` admitted `opDisputeTimeoutMs = 0`, the exact value the
  comment beside it argues against: a dispute expirable the block after it opens. Now `> 0`, with `O6`'s
  first tests of any kind.
- `NEW-CS-1` — `profile_credential` is now a fold over the credential records
  (`Storage.deriveProfileCredential`) instead of two incremental writes, so neither the profile row nor
  the claim depends on arriving first. Two tests in the replay order that no existing test had.
- `OC-12` — `mintOracleNFTAndLockDatum` now asserts `oracleParamsAreWellFormed` before submitting, which
  is the one place `O6` never runs.
- `NEW-OF-3` — `/issue-attestation` refused a credential kind off chain instead of building a
  transaction `Mc2` rejects.
- `NEW-CS-2`/`NEW-GV-4` — `AttestationRow` publishes `credential`; query Swagger `1.2.0` → `1.3.0`.
- `NEW-DC-1`..`4` — both smoke scripts corrected to the two-transaction credential flow.
- `NEW-OC-2`..`4`, `NEW-DC-6`..`15`, `NEW-TD-3`, `NEW-TD-4`, `NEW-DC-16`..`22` — the blueprint prose, the
  `/claim-profile` description, the shared `AttestationType` description and the stale `Mp3` references.

### One number this pass had to arbitrate

Three passes counted the on-chain trace codes and got 63, 69 and 70. **70 is right**: a
`traceIfFalse`/`traceError` census that reads one line misses every code written on the next line
(`A1` at `AttestationsValidator.hs:163`, `D2` at `DisputesValidator.hs:231`, `Md2`, `Mj`, `Mp2`, `N2`)
and also misses `U0`, which is passed to `parseData` at `Utils.hs:60`. `P8` and `P9` appear only in the
comment that records their burning and are correctly excluded. `K3` and `Mp3` no longer exist. Any
future document publishing a count should derive it from short string literals on non-comment lines, not
from the call shape.

### §3's do-first list, as it stands

One of the 22 rows is done (row 6, `OC-02`), two are half done (row 11's grant, row 21's wire), and
rows 4, 7, 8 need their fix text rewritten before anyone applies them. Row 17 (`TD-04`) is now **21 of
70** codes untested rather than 22 of 63 — the drop is `K3`'s deletion and nothing else, and all seven
codes added since the snapshot arrived with validator-level tests. `Mp6` and `O6`, the two security
fixes of 2026-10-22 that the report singled out as untested, are the two that still matter: `O6` gained
tests in this pass, `Mp6` has none.

### The architecture set

All three reference documents in [`../architecture/`](../architecture/README.md) were kept and
corrected in place — 134 edits, field/constructor/index level against the current types and
validators, every `path:line` re-checked, all 26 mermaid blocks re-rendered from their edited source,
no section renumbered and no diagram orphaned. Two sections were added rather than changed
(`onchain-flows.md` §3.11 for the credential-claim anatomy and §3.12 for `ExpireDispute`), both
table-only, which is why the positional `<doc>-NN.svg` mapping still holds.

**Six** of their errors were **already false at `4eb9117`** rather than drift. The count is six and
not the eleven an earlier draft of this paragraph claimed: a second pass against
`git show 4eb9117` cleared five of the candidates as ordinary drift, including three that read as
pre-existing errors and were not — the exact-value helper's line range, the "no validator branches on
the kind" citation, and `Mp6`'s justification, all of which were correct when written.

The four that matter:

- the component diagram put `onchain-lib` behind an external node labelled "atlas-cardano, cardano-api,
  plutus-*", where "no off-chain deps in `onchain-lib`" is a load-bearing claim of the document and of
  the architecture;
- "`AcceptAttestation` is the protocol's single irreversible write", which D-C's own comment refutes: a
  verdict is written once and nothing here burns, so every mint is permanent too. The conjunction of
  irreversible **and** unreachable by the pause is what made acceptance the urgent case;
- `D6` offered as what limits a transaction to one dispute. It bounds script *instances*, not one
  dispute's own obligations, so the `disputeDepositTo`-is-this-validator case that destroys the deposit
  slips through — a finding that predates D-A;
- "30 routes" for query-api against a `check_swagger.sh` that asserted `29 paths` at that very commit,
  and "41 test modules" against a cabal that listed 40 and the document's own index, which named 40.

`U2`/`U3`'s unreachability is **not** among them, and the first draft of this section put it there. The
documented chain was real at `4eb9117`: both profile lookups called
`checkAndGetCurrentStateDatumAndValue`. `3654f57` deleted those callers and, in the same commit, added
the Haddock asserting that validators call it — so the finding is that commit's, not the snapshot's,
and it is `NEW-OC-5`. Both corrections here came from preferring an agent's intermediate notes over its
final report; the documents themselves never carried either error.
