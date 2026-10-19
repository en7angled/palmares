# Experiment A — measurements

Appended to by `./measure.sh`, one `##` section per run. See README.md §"Reading the results".

Stack under measurement:

| | |
|---|---|
| db-sync | `ghcr.io/blinklabs-io/cardano-db-sync:13.7.1.0@sha256:2a341eb3…54eb950` (arm64), cap 2.0 CPU / 6144M |
| node | `ghcr.io/blinklabs-io/cardano-node:11.1.2@sha256:3620624c…62c11d` (arm64), cap 1.0 CPU / 3584M |
| postgres | `postgres:17-alpine@sha256:b0f9560a…52b24` (arm64/v8), cap 0.75 CPU / 2048M |
| insert_options | `preset: only_governance` + `offchain_vote_data: enable` + `shelley: {enable: true}` |
| host | macOS aarch64, Docker 29.8.2, 4 CPU, 16.5 GB RAM |

<!-- measure.sh appends below this line -->

## 2026-10-19T21:14:29Z  —  elapsed 25s (0h), syncing

| field | value |
|---|---|
| elapsed since db-sync start | 25 s |
| db_block_height | 85456.0 |
| node_block_height | 5311877.0 |
| lag_blocks | 5226421 |
| db_slot_height | 1795877.0 |
| db_queue_length | 47.0 |
| epoch_sync_number | 6.0 |
| epoch_sync_duration_seconds | 5.482947919 |
| cgroup memory.peak (bytes) | 71921664 |
| cgroup memory.stat anon (bytes) | 61878272 |
| db-sync RestartCount / OOMKilled | 0 / false |
| pg_database_size(cexplorer) | 47 MB |
| db-sync state dir | 4.0K |
| node chain db | 19G |

### Probes — do the options do what D-4/D-5 claim?

```
stake_deregistration | 0
pool_update | 3
drep_distr | 0
off_chain_vote_data | 0
off_chain_vote_fetch_error | 0
voting_anchor | 0
drep_distr max epoch_no | 
```

### pg_total_relation_size, top 20 (hardware-independent: this is the PVC answer)

```
block | 36 MB | 37732352
slot_leader | 136 kB | 139264
tx | 64 kB | 65536
schema_version | 56 kB | 57344
pool_update | 48 kB | 49152
stake_address | 48 kB | 49152
pool_hash | 48 kB | 49152
epoch_stake | 48 kB | 49152
cost_model | 48 kB | 49152
meta | 48 kB | 49152
epoch_stake_progress | 40 kB | 40960
epoch_sync_time | 40 kB | 40960
epoch_param | 32 kB | 32768
pool_relay | 32 kB | 32768
off_chain_pool_data | 32 kB | 32768
ada_pots | 32 kB | 32768
param_proposal | 32 kB | 32768
stake_registration | 32 kB | 32768
off_chain_pool_fetch_error | 32 kB | 32768
pool_stat | 32 kB | 32768
```

### db-sync log, last 5 lines

```
  Previous Block: , hit rate: 50%, hits: 21558, misses: 21558
  TxId: cache size: 5, cache capacity: 150000, hits: 0, misses: 0
-----------------------------------------------------------------
[34m[db-sync-node:Info:151][0m [2026-10-19 21:14:29.93 UTC] Starting epoch 8
[34m[db-sync-node:Info:151][0m [2026-10-19 21:14:29.93 UTC] Insert Alonzo Block: epoch 8, slot 1814405, block 86461, hash 1946a21ef902c25991f578e5886a4cd9b4dd58aa13c1cff378655ba6e60396d5
```
