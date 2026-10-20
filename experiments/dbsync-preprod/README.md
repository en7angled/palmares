# Experiment A — can db-sync 13.7.1.0 sync preprod with the governance options?

Throwaway infrastructure. It exists to answer one question, off-cluster, before anything is
deployed to the minirack. Once the numbers are in, this directory is deleted and its shape is
promoted into the repo's top-level `compose.yaml` (`f1-preprod-infra.md` §4.1) and into
`apps-k8s-configs/chains/cardano/preprod-dbsync/`. Nothing here is a deliverable.

## What it decides

> Does `cardano-db-sync` 13.7.1.0 with `preset: only_governance` + `ledger: enable` +
> `shelley: enable: true` + `offchain_vote_data: enable` complete a **from-genesis preprod sync at
> all** — in what wall-clock, at what on-disk size, at what peak memory?

This is the riskiest unknown in F1 (`f1-synthesis.md` §5). No published figure exists for any
preset on any architecture; upstream documents RAM for *mainnet* only. The config is frozen by the
sync — flipping `shelley` or correcting `preset` afterwards is a full re-sync — so the first sync
is effectively one shot, and §3 steps 12, 13 and 25 plus F1 checks 1-7 and 12 are all downstream
of it.

Four outputs, each with a decision attached:

| Measurement | Decides |
|---|---|
| wall-clock to tip (+ `epoch_sync_duration_seconds`) | whether the Pi run is a 1-2 day step or a week; bounded from here by the single-core ratio (~3-5x) |
| `pg_total_relation_size`, top 20 | the 50 Gi PVC on `local-path`, which has `allowVolumeExpansion: false` — it is sized once, forever. Hardware-independent, so this number is final |
| cgroup peak memory under a **6144M** cap | whether `deployment-palmares-dbsync`'s 4Gi/6Gi request/limit holds on `minirack-pi5-1`, or `ledger_backend: lsm` has to be reconsidered |
| `count(*)` on `stake_deregistration`, `pool_update`, `drep_distr`, `off_chain_vote_data`, `off_chain_vote_fetch_error` (+ `voting_anchor`, `max(drep_distr.epoch_no)`) | that the `shelley` flip took (D-4), that `drep_distr` is populated for every Conway epoch (F1 check 1), and the anchor-coverage number `f1-api-contract.md` §8.5 defers — which in turn decides whether a supplementary anchor re-fetcher is needed at all |

**If it does not fit, the spec §4.1 substrate decision reopens** — in week 1 instead of week 6.
That is the whole value of running it here rather than on the cluster.

## Before you start

Docker Desktop: **4 CPUs, 12 GB memory, 100 GB disk image**. The three containers cap at
3.5 + 2 + 6 = 11.5 GB and 3.75 CPUs, which leaves macOS ~4.5 GB and keeps the Mac usable.
Measured host on 2026-10-19: Docker 29.8.2, aarch64, 4 CPU, 16.5 GB RAM, 161 GB free.
On-disk footprint when done: node ~21 GB + db-sync state ~2 GB + Postgres 10-18 GB ≈ **35-41 GB**.

No secret, token or key is needed anywhere in this experiment. `POSTGRES_PASSWORD` defaults to
`devonly` and no host port is published, so Postgres is reachable only from the two sibling
containers and `docker compose exec`.

## Running it

```bash
cd experiments/dbsync-preprod
./run.sh                                   # start, or resume after a stop/reboot
docker compose logs -f cardano-db-sync     # watch
./measure.sh                               # one row into measurements.md — run it hourly
docker compose stop                        # pause; ./run.sh resumes from the last stored block
docker compose down -v                     # STOP AND DESTROY, including the ~40 GB of volumes
```

`run.sh` verifies `node-config/SOURCES.sha256` before it starts anything and refuses to run if a
genesis file has drifted — db-sync replays the ledger against those bytes, so a silent edit
invalidates the measurement rather than failing it.

Expect: the node restores from Mithril for ~20-40 min (no socket until it finishes, which is why
the healthcheck has `start_period: 60m` and db-sync `depends_on: service_healthy`), then db-sync
starts its own from-genesis pass. Both services are `restart: unless-stopped`, so the run survives
a crash; `measure.sh` reports `RestartCount` and `OOMKilled` so a crash is never mistaken for
progress. Leave it 48 h.

## Reading the results

`measurements.md` gets one `##` section per `measure.sh` run.

- **Wall-clock to tip** = the `elapsed since db-sync start` of the first row whose `lag_blocks`
  is `<= 1` (the row is marked `**AT TIP**`). It is computed from the container's `StartedAt` and
  db-sync's own `cardano_db_sync_{db,node}_block_height` gauges, scraped from `localhost:8080/` —
  note **`/`, not `/metrics`**: db-sync calls `serveMetricsT port []`, so `/metrics` is a hard 404.
- **PVC answer** = the last `pg_database_size` row, and the top-20 table for where it went.
  `epoch_stake` is expected to dominate (~320 preprod epochs).
- **Memory** = `cgroup memory.peak`, which is anon + page cache, i.e. exactly what a Kubernetes
  memory limit enforces — so it is the number the Pi's 6Gi limit must clear, not a pure-RSS figure.
  `memory.stat anon` beside it is the true-RSS comparison.
- **Probes** — `stake_deregistration > 0` and `pool_update > 0` prove `shelley: enable: true` took
  (with it false, both are empty). `drep_distr max epoch_no` within 1 of the current preprod epoch
  proves `ledger: enable` survived the preset. `off_chain_vote_data / voting_anchor` is the anchor
  coverage rate; `off_chain_vote_fetch_error` is its complement, and if more than ~20 % of anchors
  are still unfetched 48 h in, the deferred re-fetcher gets its trigger.

## Decisions taken here, and why

**Mithril: yes, for the node, and it is the image's own default.** `RESTORE_SNAPSHOT` defaults to
`true` in blinklabs' `run-node`, which restores the chain DB with `--include-ancillary` when the
data dir is empty, so there is no `mithril-client` service to write. It genuinely shortens *this*
experiment, for a reason worth stating precisely: **Mithril does nothing for db-sync.** It restores
the *node's* chain database; db-sync still streams every block from genesis over local chain-sync
and maintains its own ledger state, and no preprod db-sync Postgres snapshot exists to restore
(`update-cardano-preprod.iohk.io` does not resolve). Mithril's value is that it removes the node's
6-10 h genesis download from the critical path, so the measured wall-clock is db-sync's own work
rather than db-sync waiting for blocks. The thing being measured is untouched by it.

**Pinned node config instead of `NETWORK: preprod`.** The official preprod set is fetched from
`book.play.dev.cardano.org`, hash-pinned in `node-config/SOURCES.sha256`, and bind-mounted
**read-only at the same path in both containers**, so db-sync's `NodeConfigFile` and the node's
`--config` are byte-identical by construction. `NETWORK: preprod` would instead route the
entrypoint through `run-network` and the image's own unpinned bundle.

**db-sync capped at the Pi's own 6144M limit**, not at whatever the Mac can spare. Completing
under the cap proves the cluster limit; an OOM kill under it is the single most useful bad news
this experiment can produce.

## Known gap this experiment does not close

The official preprod `config.json` pins `LedgerDB.Backend: V2InMemory`; the cluster's preprod node
runs **`V2LSM`**. Whether db-sync tolerates a node config carrying the `V2LSM` block is still open
(`f1-synthesis.md` §6). It is a 5-minute check, not a 48-hour one: once this run is at tip, edit
`LedgerDB.Backend` to `V2LSM` in `node-config/config.json`, `docker compose up -d --force-recreate
cardano-db-sync`, confirm it does not die in its first 60 s, then revert the file and re-verify
`SOURCES.sha256`. Do it *after* the headline numbers are recorded, never during.

## No sampler is needed (and that is deliberate)

An earlier attempt added an hourly `measure.sh` loop. It is gone, because it measured nothing new:

- **Peak memory** comes from cgroup v2's `/sys/fs/cgroup/memory.peak`, which the kernel maintains as a
  **cumulative high-water mark** for the container's whole lifetime. One read at the end is exactly as
  accurate as 48 hourly reads — and strictly better than sampling, which can miss a spike between samples.
  (It resets if a container restarts, so `measure.sh` also reports `RestartCount` and `OOMKilled`.)
- **The per-epoch timing curve** is already in db-sync's own log, which `measure.sh` tails and which
  `docker compose logs` keeps in full.
- **Table sizes** are a `pg_total_relation_size` query that is only meaningful once the sync is done.

So: run `./measure.sh` whenever you want a snapshot row, and once more when it reaches tip. Nothing has
to stay running alongside the experiment.

---

## Status 2026-10-20: measurements landed, rig retained on purpose

Experiment A answered its question. db-sync reached the preprod tip from genesis in **≤ 7 h** and now
follows live; every number is in `docs/adr/0001-governance-data-substrate.md`, and the compose file plus
both config directories have been promoted to the repo root (`compose.yaml`,
`deploy/dbsync/db-sync-config.yaml`, `deploy/node-config/`).

By the rule in the repo README this directory should now be deleted. It is not, for one reason: **its
volumes hold the only synced preprod db-sync database on this machine**, and the SQL/metrics block needs
a real one to write and check views against. Re-creating it costs another ~7 h plus 34 GB.

**Delete this directory when** the top-level `compose.yaml --profile chain` stack has its own synced
database, or when the cluster substrate is up. Until then, do not `docker compose down -v` here.
