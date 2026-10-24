# Palmares

**A public, verifiable track record for Cardano governance.**

Palmares derives every DRep's complete governance history — votes, vote delegations, rationale anchors,
per-epoch voting power, committee and treasury activity — directly from the chain, publishes it through a
free public API and explorer, and lets organizations issue **countersigned attestations** (a claim is only
recorded once its subject accepts it) about delivery, audits and affiliations.

Built for the Cardano community. No token, no protocol fees, no paywall.

## 1. Why you can trust the numbers

Every figure Palmares shows is **re-derivable by anyone, from genesis, using open-source software only**:
`cardano-node` + `cardano-db-sync` + this repository. We add no ledger math of our own — the governance
state comes from db-sync's replay of the Haskell ledger rules, and our layer is a set of read-only SQL
views over it. Koios is used as an independent cross-check, never as a source.

Two rules follow from that, and they are not negotiable:

- **Published formulas.** Every metric ships with the SQL that defines it, served at
  `/metrics/formulas` and rendered next to the number. `docs/metrics.md` is generated from that catalog,
  so the documentation cannot drift from the code. One statement is executed verbatim; the five DRep
  metrics are served from a materialized view that computes the same arithmetic for every DRep at once,
  and its agreement with the published statements is asserted by a test rather than claimed — see
  `docs/metrics.md`.
- **No opaque scores.** Palmares reports facts with pinned denominators. It does not rank DReps by a
  composite rating, does not infer intent, and does not tell you who to delegate to.

## 2. Two doors, honestly labelled

- **The read path is fully self-hostable.** Node, db-sync, the API and the explorer need no account, no
  API key and no paid service. If you do not trust our instance, run your own and compare.
- **The write path needs one key of your own.** Submitting an attestation transaction is built through a
  chain provider; you supply your own token. We never hold your keys — transactions are built unsigned
  and signed in your wallet (CIP-30 / CIP-95).

## 3. What it is not

Not a voting tool, not a wallet, not a forum, not a KYC service, and not a replacement for
[GovTool](https://gov.tools). It is the missing memory layer: what each actor actually did, over time,
provably.

## 4. Status

Early development. The first milestone runs the complete product on **preprod**; mainnet follows once the
substrate and validators have soaked. See `docs/adr/` for the decisions and their measurements.

## 5. Architecture

```
cardano-node ──▶ cardano-db-sync (preset only_governance, ledger enabled) ──▶ PostgreSQL
                                                                                 │
                          palmares.* read-only SQL views + one materialized view ┤
                                                                                 ▼
   attestation validators ──▶ Kupo ──▶ palmares_attest.* ──▶ query-api (public) ──▶ explorer / API clients
```

Four Haskell libraries (`onchain-lib`, `offchain-lib`, `chainsync-lib`, `webapi-lib`) and four binaries
(`admin`, `query-api`, `interaction-api`, `attest-sync`). On-chain validators are PlutusTx/Plinth; the
transaction-building stack is Atlas.

## 6. Repository layout

| Path | What lives there |
|---|---|
| `src/lib/` | the four libraries, dependencies pointing inward only |
| `src/exe/` | the four executables |
| `src/test/` | unit, property and emulator tests |
| `sql/` | the schema, the views and the metric SQL, applied at service boot |
| `resources/metrics/` | one `.sql` per metric, embedded at compile time — the single source of truth |
| `docs/spec/` | the specification the code cites, the metric decisions, and the `D-`/`F-` identifiers |
| `docs/adr/` | decision records, each carrying the measurements behind it |
| `docs/generated/` | generated Swagger and CIP-57 blueprint — committed, never hand-edited |
| `docs/deployment/` | the runbooks: the attestation-flow smoke test and the Koios parity gate |
| `docs/metrics.md` | generated from `resources/` by `admin write-metrics-doc` — the published formulas, rendered |
| `docs/audit/` | the 2026-10-22 audit; §3 of its README is the list kept current |
| `docs/architecture/` | reference diagrams for the on-chain protocol, its flows, and the system |
| `scripts/` · `config/` · `deploy/` | maintained tooling · the provider and validator configs (gitignored, with committed templates) · db-sync's configuration, the single source for the k8s ConfigMap |
| `experiments/` | the measurement rigs behind the ADRs, kept while an ADR still cites one |

## 7. Governance data provenance

The substrate is `cardano-db-sync` with `preset: only_governance` and the ledger **enabled**. The sync is
run **from genesis**, deliberately: db-sync documents that pre-upgrade `drep_distribution` values are not
well defined and can differ between executions, and recomputing from genesis is the documented remedy.
A snapshot restore is therefore not an acceptable shortcut for this data. See
`docs/adr/0001-governance-data-substrate.md`.

## 8. Contributing

Issues and pull requests are welcome. The read path is designed so that a contributor can reproduce the
whole dataset locally; `compose.yaml` brings up node + db-sync + Postgres + the API.

Enable the pre-push checks once per clone — git never propagates hooks:

```bash
git config core.hooksPath .githooks
```

## 9. Licence

Apache-2.0 (`LICENSE`). Portions are derived from the author's own MIT-licensed
[Decentralized Belt System](https://github.com/en7angled/Decentralized-Belt-System); see `NOTICE` and
`licenses/`.

## 10. Build from source

The toolchain is pinned: GHC 9.6.6 via Nix + direnv, and every dependency is fixed by `cabal.project`
plus the committed `cabal.project.freeze`. No version floats, so a build either reproduces or fails
loudly.

```bash
git config core.hooksPath .githooks        # enable the pre-push checks (git never propagates hooks)
cp .env.example .env                       # then fill it in; .env is gitignored and never committed
direnv allow                               # first run pulls the devx closure (~8-12 GB, once)
cabal update
cabal build all

# `cabal test` needs an empty PostgreSQL of its own — 85 of the cases connect to one, and without
# the variable they fail in 14 seconds looking like a broken checkout. Use 127.0.0.1 and not
# localhost: a port published by Docker is on 127.0.0.1 only, and localhost resolves to ::1 first.
docker run -d --name palmares-test-pg -p 127.0.0.1:55439:5432 \
  -e POSTGRES_PASSWORD=devonly postgres:17-alpine
export PALMARES_TEST_PG_CONN_STR="host=127.0.0.1 user=postgres password=devonly dbname=postgres port=55439"
cabal test
```

`PALMARES_FIXTURE_PG_CONN_STR` is optional and points at a synced preprod db-sync; without it the
epoch-320 metric-fixture gate reports `SKIPPED` inside passing cases, so "all tests passed" does not
mean that gate ran. `PALMARES_REQUIRE_FIXTURE_GATE=1` turns that skip into a failure — the preprod
signing run sets both variables, so "the gate passed" cannot mean "the gate did not run".

Containers, and the read-path stack. Two profiles, matching the two doors of §2:

```bash
scripts/build-images.sh                    # all four service images, host architecture, loaded locally
docker compose --profile chain up -d       # node + db-sync + Postgres: the whole read path
docker compose --profile app   up -d       # + the public query API on :8083, as palmares_owner

# The write path, once `admin deploy-reference-scripts` has run. BASIC_USER and BASIC_PASS have no
# defaults — a shipped credential is worse than a missing one — so compose names the one you forgot.
BASIC_USER=you BASIC_PASS=secret docker compose --profile write up -d
```

Every published port binds to `127.0.0.1`, including Postgres. The `write` profile brings up Kupo,
the interaction API **and `attest-sync`**: without the last one the stack can submit an attestation
to the chain and never read it back, which is what the audit found.

Time until useful, measured 2026-10-20 on an Apple-silicon laptop (Experiment A, numbers in
`docs/adr/0001-governance-data-substrate.md`):

| Step | Wall clock | Why |
|---|---|---|
| node, via Mithril | ~20–40 min | the default; set `RESTORE_SNAPSHOT=false` for a genesis audit run |
| db-sync from genesis | **≤ 7 h** | caught up at ~9× real time, then follows live at 1:1 |

Footprint when synced: node 20.2 GB + db-sync state 2.9 GB + Postgres 10.4 GB ≈ 34 GB; peak memory
5.90 GiB for db-sync, 2.74 GiB for the node.

A from-genesis sync is a deliberate correctness requirement, not a default we never got around to
changing — see §7 and the ADR. `deploy/dbsync/db-sync-config.yaml` is the single source for db-sync's
configuration; the Kubernetes ConfigMap is generated from it, never forked.

## 11. Configuration

Every name below is read from the environment (direnv sources `.env`). `fail-closed` means the service
exits rather than starting with an unsafe default.

| Name | Status | Used by |
|---|---|---|
| `BASIC_USER` | required, **fail-closed** | interaction-api |
| `BASIC_PASS` | required, **fail-closed** | interaction-api |
| `CORS_ALLOWED_ORIGINS` | optional; unset or empty denies all cross-origin, which is the safe default and not a boot failure | query-api, interaction-api, attest-sync |
| `PG_CONN_STR` | required — db-sync's own database, the pool that serves requests | query-api, attest-sync |
| `PALMARES_PG_OWNER_CONN_STR` | optional; the owner pool for the boot DDL and the matview refresh. Unset, it falls back to `PG_CONN_STR` | query-api |
| `ATLAS_CORE_CONFIG` | write path; **the JSON itself**, not a path — unset reads `config/config_atlas.json` | interaction-api, attest-sync, admin |
| `DEPLOYED_VALIDATORS_CONFIG` | write path; **the JSON itself**, not a path — unset reads `config/config_palmares_validators.json` | interaction-api, attest-sync, admin |
| `PORT` | default `8083` query-api · `8082` interaction-api · `8084` attest-sync | all services |
| `KUPO_URL` | required, **fail-closed** — no default: the projector's only view of the chain | attest-sync |
| `FETCH_BATCH_SIZE` | slots per fetch window; default `10000000` in the binary, `100000` as the images and `compose.yaml` set it | attest-sync |
| `ROLLBACK_MARGIN` | default `2160` | attest-sync |
| `READY_MAX_LAG_SLOTS` | default `1200` — the slot gap at which `/ready` turns red, and the same number in seconds bounds how long the projector may go without an answer from Kupo. Unparseable or non-positive falls back to the default rather than failing the boot | attest-sync |
| `PALMARES_VIEW_REFRESH_SECONDS` | default `300` | query-api |
| `PALMARES_READY_MAX_LAG_SECONDS` | default `300` — `/ready` red above this | query-api |
| `PALMARES_AMBER_LAG_SECONDS` | default `120` — UI amber above this | query-api |
| `PALMARES_NETWORK_NAME` | default `preprod` — the value `/ready` compares `meta.network_name` against | query-api |
| `PALMARES_FRESHNESS_POLL_MS` | default `5000` | query-api |
| `PALMARES_ADMIN_CONN_STR` | required by `apply-indexes` and `apply-roles`, **fail-closed** — the superuser DSN, deliberately not `PG_CONN_STR` | admin |
| `PALMARES_OWNER_PASSWORD` · `PALMARES_RO_PASSWORD` | required by `apply-roles`, **fail-closed** — it never invents a password | admin |
| `PALMARES_API` · `KOIOS_API` · `KOIOS_API_TOKEN` | the parity gate's two base URLs and an optional Koios token; `PALMARES_API` is **query-api's** base | admin |
| `PALMARES_TEST_PG_CONN_STR` | required by `cabal test` — see §10 | test suite |
| `PALMARES_FIXTURE_PG_CONN_STR` | optional; a synced preprod db-sync for the epoch-320 metric gate — unset, that gate reports `SKIPPED` inside passing cases | test suite |
| `PALMARES_REQUIRE_FIXTURE_GATE` | optional; any non-empty value makes a skipped epoch-320 fixture case a **failure** rather than a pass. Set it on the preprod signing run; CI sets it alone, on a filtered run, to assert the skip can never read as green | test suite |

`BATCH_SIZE` was removed from this table, from `.env.example` and from `Dockerfile.attest-sync`: it was
set in three places and read in none.

There is **no** provider-token variable in this list: Atlas reads the provider out of the core config,
never from the environment. `config/config_atlas.example.json` is the committed template and carries
`REPLACE_ME`; the real `config/config_atlas.json` is gitignored.

The template's `coreProvider` is `{"blockfrostKey": …}` — a project key of your own, for the network you
are on. Atlas picks the provider from **which keys are present**, so put exactly one provider in that
object: `blockfrostKey`, or `socketPath` + `kupoUrl`, or `ogmiosUrl` + `kupoUrl`. Mixing two lets the
first shape that parses win silently. (`maestroToken` is a fourth shape Atlas still accepts, but Maestro
withdrew its Cardano API in 2026 and the hostname no longer resolves.)

**If you run a node yourself, you need no key at all.** `{"socketPath": …, "kupoUrl": …}` is measured
rather than aspirational — see [ADR 0004](docs/adr/0004-maestro-withdrew-its-cardano-api.md) — and it
leaves the write path with no secret. Kupo must run with `--match '*'`: the builder resolves the admin
wallet's own UTxOs, the four validator addresses — which change whenever the scripts do — and Atlas's
limbo address, where the reference scripts are locked. On macOS the node
socket is reachable only from inside the compose project, never from a host CLI.
