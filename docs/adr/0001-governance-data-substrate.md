# ADR 0001 — Governance data substrate

Status: accepted; measurements landed 2026-10-20 (PVC sizing and the memory fork still open)
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

Experiment A, preprod from genesis on Docker/arm64 (Apple silicon), read 2026-10-20 at epoch 320,
block 5,313,085. Node and Postgres were on the same host, so the timings are a lower bound for the Pi.

| Measurement | Value | Source |
|---|---|---|
| wall-clock to tip (preprod, from genesis) | **≤ 7 h** — caught up at ≈9× real time, then followed live at 1:1 (114 slots per 114 s of wall clock). The exact crossover was not logged. | Experiment A |
| database size | 5,909 MB logical / **10.43 GB** Postgres volume | `pg_database_size`, `docker system df -v` |
| top relations | `block` 2,323 MB · `tx` 1,759 MB · `epoch_stake` 747 MB · `voting_procedure` 331 MB · `reward` 324 MB · `stake_address` 145 MB · `committee_hash` 135 MB · `committee_registration` 56 MB | `pg_total_relation_size` |
| db-sync ledger state on disk | **2.9 GiB** (3 retained snapshots) | `du -sh /var/lib/cexplorer` |
| node chain db | 20.18 GB | volume size |
| peak RSS of db-sync | **5.90 GiB anonymous** (file cache only 75 MiB) against a 6 GiB cap; `memory.peak` reached the cap exactly, `memory.events` recorded 4,183 `max` reclaim events and **0 OOM kills** | cgroup v2 `memory.stat`, `memory.peak`, `memory.events` |
| peak RSS of the node | 2.74 GiB anonymous + 540 MiB file | same |
| PVC verdict | **open** — blocked on the memory call below, not on data | — |
| `drep_distr` | 17,399 rows over 157 epochs (164–320), ≈111 per epoch; 195 at epoch 319 | `drep_distr` |
| `stake_deregistration` / `pool_update` non-empty (proves the `shelley` flip took) | **17,707 / 1,403 — flip confirmed** | row counts |
| anchor coverage | **94 resolved vs 1,508 fetch errors (5.9%)** — preprod test anchors mostly point at dead URLs | `off_chain_vote_data`, `off_chain_vote_fetch_error` |
| governance volume | 131 gov actions · 3,244,708 votes (3,243,802 of them CC) · 811 DRep hashes · 8,118 vote delegations · 110 committee members · 83 treasury withdrawals | row counts |

### What the memory number does and does not establish

It establishes the **ceiling**: db-sync syncs preprod from genesis to tip inside 6 GiB without being
OOM-killed. It does **not** establish the floor. GHC's RTS sizes its heap from the host's `/proc/meminfo`,
not from the cgroup limit, so the process grew into the space it believed it had while the cgroup reclaimed
4,183 times. The live set may be considerably smaller. Two ways forward, and they are a real fork:

1. Move Postgres to another node and give db-sync all of pi5-1's free memory. No new measurement needed.
2. Cap the heap (`GHCRTS=-M…`) and re-run from genesis under the Pi's real budget. Costs ~7 h and answers
   the question option 1 avoids.

Until one is chosen, the PVC stays unsized — `local-path` has `allowVolumeExpansion: false`, so the size is
permanent. Inputs for whichever is chosen: 10.43 GB Postgres + 2.9 GiB db-sync state today, growing with the
chain.

## Consequences

- `shelley: enable: true` must be in the config **before the first sync starts**; flipping it later costs
  a full re-sync.
- `epoch_stake` is inserted unconditionally whenever the ledger is enabled and is unused by this product.
  Measured: 4,726,567 rows / 747 MB — **not** the largest table, as this ADR originally assumed. `block`
  (2,323 MB) and `tx` (1,759 MB) are, and together they are 69% of the database. So pruning `epoch_stake`
  buys only ~13% of the disk and is a weak first fallback; on preprod the whole database is small enough
  that none of this matters, and on mainnet the lever is hardware, not pruning.
- `tx.fee` is `0` under this preset (`tx_out: disable`), `off_chain_pool_data` is empty (SPO pages show
  hashes, not tickers), and constitution anchors are never fetched. These are accepted limitations.
- Mainnet needs a 48–64 GB x86_64 host; the arm64 Pi cluster is preprod-only for this workload.
