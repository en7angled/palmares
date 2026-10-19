# ADR 0001 — Governance data substrate

Status: accepted (measurements pending)
Date: 2026-10-20

## Decision

Governance data comes from **cardano-db-sync 13.7.1.0** (image `ghcr.io/blinklabs-io/cardano-db-sync`,
pinned by digest; arm64), with `preset: only_governance`, `ledger: enable`, `shelley: enable: true` and
`offchain_vote_data: enable`. Our layer adds two schemas to db-sync's own `cexplorer` database —
`palmares` (fourteen read-only views, one materialized view, one SQL function) and `palmares_attest` —
and no governance projection tables.

The sync is run **from genesis**. This is a correctness requirement, not a completeness one: db-sync's
13.6.0.4 Known Issue states that pre-upgrade `drep_distribution` values "are not well defined and could
be slightly different between different executions" (naming preprod explicitly), and issue #1975 records
two identical instances disagreeing on one DRep's epoch-538 voting power by ~740×. The documented remedy
is to discard ledger-state files and recompute, which is what a from-genesis sync does. A Postgres
snapshot restore or an in-place upgrade is therefore **not** an acceptable shortcut. Mithril remains fine:
it bootstraps the *node*, not db-sync's ledger state.

### Alternatives considered

**A custom Ogmios follower** (the original plan): rejected. Per-epoch DRep voting power, ratification
thresholds and gov-action outcomes are epoch-boundary ledger state, not block facts, so a follower would
have to reimplement db-sync's core loop — the part reviewers and contributors would trust least.

**Yaci-Store 2.0.7**: rejected as substrate. Its `drep_dist` depends on the UTxO store (account →
stake-address-balance → snapshot), so it must index the entire UTxO set to produce per-epoch DRep power —
heavier than `only_governance`, which gets it from the ledger replay with `tx_out` disabled.
`GovActionStatus` carries only `{ACTIVE, RATIFIED, EXPIRED}` (no ENACTED/DROPPED, upstream issue #1194).
It stores `anchor_url`/`anchor_hash` only, with no off-chain fetching or hash verification, which would
resurrect a component we delete here. Its per-epoch range partitioning needs ~3,160 locks for one
unbounded `drep_dist` query (issue #1200), and its baseline migration opens with
`drop table if exists drep_dist cascade`, which would silently drop our views. It is also **not** a
fallback under disk pressure, being structurally heavier; the fallback there is x86_64 hardware.
Full evaluation and the T1–T7 monitorable triggers that would reopen this: see the design notes in the
originating repository.

## Measurements

Filled by the sizing task once the from-genesis sync completes. Required rows:

| Measurement | Value | Source |
|---|---|---|
| wall-clock to tip (preprod, from genesis) | _pending_ | Experiment A + cluster sync |
| `pg_total_relation_size`, top 20 tables | _pending_ | `scripts/measure_substrate.sh` |
| peak RSS of the db-sync process | _pending_ | container metrics |
| PVC verdict (sized once — `local-path` has `allowVolumeExpansion: false`) | _pending_ | — |
| `drep_distr` rows per Conway epoch | _pending_ | — |
| `stake_deregistration` / `pool_update` non-empty (proves the `shelley` flip took) | _pending_ | — |
| anchor coverage: resolved vs `not_fetched` | _pending_ | — |

## Consequences

- `shelley: enable: true` must be in the config **before the first sync starts**; flipping it later costs
  a full re-sync.
- `epoch_stake` is inserted unconditionally whenever the ledger is enabled and is unused by this product —
  it will be the largest table in the database. A pruning CronJob is the first disk fallback, and only
  after a test pins db-sync's own read-back of that table.
- `tx.fee` is `0` under this preset (`tx_out: disable`), `off_chain_pool_data` is empty (SPO pages show
  hashes, not tickers), and constitution anchors are never fetched. These are accepted limitations.
- Mainnet needs a 48–64 GB x86_64 host; the arm64 Pi cluster is preprod-only for this workload.
