# ADR 0001 — Governance data substrate

Status: accepted; measurements landed 2026-10-20 and re-measured 2026-10-21 by
`scripts/measure_substrate.sh` (PVC sizing and the memory fork still open — see the fork below)
Date: 2026-10-20

## Decision

Governance data comes from **cardano-db-sync 13.7.1.0** (image `ghcr.io/blinklabs-io/cardano-db-sync`,
pinned by digest; arm64), with `preset: only_governance`, `ledger: enable`, `shelley: enable: true` and
`offchain_vote_data: enable`. Our layer adds two schemas to db-sync's own `cexplorer` database —
`palmares` (nineteen read-only views, one materialized view, two SQL functions and one single-row
`schema_fingerprint` table that gates the boot DDL) and `palmares_attest` — and no governance
projection tables.

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

__Reproduce with `scripts/measure_substrate.sh`.__ Every number below comes out of that script, and
that is the point of it existing: a figure the PVC decision rests on must be re-runnable, or it ages
into a claim nobody can check. The script runs against Experiment A today and against the cluster
once T-SUBSTRATE-3/4 land — the database and relation sizes are CHAIN facts and transfer between
hosts unchanged, the memory figures are HOST facts and do not.

Experiment A, preprod from genesis on Docker/arm64 (Apple silicon), read 2026-10-20 at epoch 320,
block 5,313,085. Node and Postgres were on the same host, so the timings are a lower bound for the
Pi. The __second column is a re-read on 2026-10-21 at epoch 320, block 5,316,060__ — about ten hours
and three thousand blocks later, following the tip rather than catching up, which is what makes the
two memory readings interesting rather than redundant.

| Measurement | 2026-10-20 (catching up) | 2026-10-21 (following tip) |
|---|---|---|
| wall-clock to tip (preprod, from genesis) | **≤ 7 h** — caught up at ≈9× real time, then followed live at 1:1 (114 slots per 114 s of wall clock). The exact crossover was not logged. | Experiment A |
| database size | 5,909 MB logical / 10.43 GB volume | **6,260 MB** logical / **10.26 GB** volume |
| top relations | `block` 2,323 · `tx` 1,759 · `epoch_stake` 747 · `voting_procedure` 331 · `reward` 324 · `stake_address` 145 · `committee_hash` 135 · `committee_registration` 56 (MB) | `block` **2,530** · `tx` 1,765 · `epoch_stake` 747 · `voting_procedure` **410** · `reward` 324 · `stake_address` 146 · `committee_hash` 135 · `committee_registration` **110** |
| __our own schema__ | not measured | **0 tables, 19 views, 1 materialized view, 680 kB** — 0.01% of the database, which is the "no governance projection tables" decision as a number |
| db-sync ledger state on disk | 2.9 GiB (3 retained snapshots) | 2.9 GiB / **3.09 GB** volume |
| node chain db | 20.18 GB | **21.28 GB** |
| peak RSS of db-sync | **5.90 GiB anon** against a 6 GiB cap, **4,183** `max` reclaim events, 0 OOM kills | **5.06 GiB anon** against the same cap, **35** reclaim events, 0 OOM kills |
| peak RSS of the node | 2.74 GiB anon + 540 MiB file | 2.88 GiB anon against a 3.5 GiB cap, 59,697 reclaim events, 0 OOM kills |
| PVC verdict | **open** — blocked on the memory call below, not on data. Today's inputs: **10.26 GB Postgres + 3.09 GB db-sync state = 13.35 GB**, of which `block` and `tx` are 69% | — |
| `drep_distr` | 17,399 rows over 157 epochs (164–320), ≈111 per epoch; 195 at epoch 319 | 17,399 — unchanged, as expected inside one epoch |
| `stake_deregistration` / `pool_update` non-empty (proves the `shelley` flip took) | 17,707 / 1,403 — flip confirmed | **17,711** / 1,403 |
| anchor coverage | 94 resolved vs 1,508 fetch errors (5.9%) | 94 resolved vs **1,677** fetch errors (5.3%) — preprod test anchors mostly point at dead URLs, and the error count grows while the resolved count does not |
| governance volume | 131 gov actions · 3,244,708 votes (3,243,802 CC) · 811 DRep hashes · 8,118 vote delegations · 83 withdrawals | 131 · **3,244,711** votes (3,243,802 CC) · **814** DRep hashes · **8,123** delegations · 83 withdrawals |

### What the memory number does and does not establish

It establishes the **ceiling**: db-sync syncs preprod from genesis to tip inside 6 GiB without being
OOM-killed. It does **not** establish the floor. GHC's RTS sizes its heap from the host's `/proc/meminfo`,
not from the cgroup limit, so the process grew into the space it believed it had while the cgroup reclaimed
4,183 times. The live set may be considerably smaller. Two ways forward, and they are a real fork:

1. Move Postgres to another node and give db-sync all of pi5-1's free memory. No new measurement needed.
2. Cap the heap (`GHCRTS=-M…`) and re-run from genesis under the Pi's real budget. Costs ~7 h and answers
   the question option 1 avoids.

__The 2026-10-21 re-read narrows it without closing it.__ Following the tip, db-sync holds **5.06 GiB
anonymous with 35 reclaim events**, against **5.90 GiB and 4,183 events** while catching up. So the
steady state is about 0.8 GiB cheaper and essentially not under pressure, and the 6 GiB cap is
comfortable once synced. That does not close the fork, because __the from-genesis catch-up is the peak
and the catch-up is what has to fit__ — a cap chosen for the steady state would be chosen for the
easier half of the job. It does mean option 1 buys headroom where it is least needed and option 2 is
still the only reading that answers the real question.

The node is the quieter surprise: 2.88 GiB anonymous against a 3.5 GiB cap with **59,697** reclaim
events and no OOM kill. It is running far closer to its limit than db-sync is, and on the Pi the two
share a host.

Until one is chosen, the PVC stays unsized — `local-path` has `allowVolumeExpansion: false`, so the size is
permanent. Inputs for whichever is chosen: 10.43 GB Postgres + 2.9 GiB db-sync state today, growing with the
chain.

## Consequences

- `shelley: enable: true` must be in the config **before the first sync starts**; flipping it later costs
  a full re-sync.
- `epoch_stake` is inserted unconditionally whenever the ledger is enabled and is unused by this product.
  Measured: 4,726,567 rows / 747 MB — **not** the largest table, as this ADR originally assumed. `block`
  (2,530 MB) and `tx` (1,765 MB) are, and together they are 69% of the database. So pruning `epoch_stake`
  buys only **11.9%** of the disk and is a weak first fallback; on preprod the whole database is small
  enough that none of this matters, and on mainnet the lever is hardware, not pruning.
- The read layer this product adds is **680 kB**: nineteen views, one materialized view, zero
  governance tables, and (since `GV-01`) one single-row `schema_fingerprint` table that gates the
  boot DDL. Whatever the substrate costs, it is not us.
- `tx.fee` is `0` under this preset (`tx_out: disable`), `off_chain_pool_data` is empty (SPO pages show
  hashes, not tickers), and constitution anchors are never fetched. These are accepted limitations.
- Mainnet needs a 48–64 GB x86_64 host; the arm64 Pi cluster is preprod-only for this workload.
