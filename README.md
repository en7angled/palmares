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

- **Published formulas.** Every metric ships with the exact SQL that computes it, served at
  `/metrics/formulas` and rendered next to the number. `docs/metrics.md` is generated from that catalog,
  so the documentation cannot drift from the code.
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
| `docs/adr/` | decision records, each carrying the measurements behind it |
| `docs/generated/` | generated Swagger and CIP-57 blueprint — committed, never hand-edited |
| `experiments/` | throwaway measurement rigs, deleted once their numbers land in an ADR |

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
cabal test
```

Containers, and the read-path stack. Two profiles, matching the two doors of §2:

```bash
scripts/build-images.sh                    # all four service images, host architecture, loaded locally
docker compose --profile chain up -d       # node + db-sync + Postgres: the whole read path
docker compose --profile app   up -d       # + the public query API on :8083
```

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
| `BASIC_USER` | required, **fail-closed** | interaction-api, admin |
| `BASIC_PASS` | required, **fail-closed** | interaction-api, admin |
| `CORS_ALLOWED_ORIGINS` | required; empty = deny all cross-origin (**fail-closed**) | both APIs |
| `PG_CONN_STR` | required — db-sync's own database, one pool | query-api, attest-sync |
| `ATLAS_CORE_CONFIG` | required for the write path (JSON blob or file path) | interaction-api, admin |
| `DEPLOYED_VALIDATORS_CONFIG` | required for the write path (JSON blob or file path) | interaction-api, admin |
| `PORT` | default `8083` query-api · `8082` interaction-api · `8084` attest-sync | all services |
| `KUPO_URL` | default `http://localhost:1442` | attest-sync |
| `BATCH_SIZE` | default `1000000` | attest-sync |
| `FETCH_BATCH_SIZE` | default `100000` | attest-sync |
| `ROLLBACK_MARGIN` | default `2160` | attest-sync |
| `PALMARES_VIEW_REFRESH_SECONDS` | default `300` | query-api |
| `PALMARES_READY_MAX_LAG_SECONDS` | default `300` — `/ready` red above this | query-api |
| `PALMARES_AMBER_LAG_SECONDS` | default `120` — UI amber above this | query-api |

`MAESTRO_API_KEY` is **not** in this list: Atlas reads the provider token from the core config, never from
the environment. `config/config_atlas.example.json` is the committed template and carries `REPLACE_ME`;
the real `config/config_atlas.json` is gitignored.
