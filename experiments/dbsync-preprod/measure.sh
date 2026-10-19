#!/usr/bin/env bash
# Append one measurement block to measurements.md. Re-runnable, needs no secret (psql goes over
# the container's local socket as the `postgres` superuser; the metrics endpoint is unauthenticated
# and container-local). Run it hourly while the sync runs, and once more after it reaches tip.
#
# "Wall-clock to tip" is NOT guessed from log strings: each row records elapsed seconds since the
# db-sync container started plus db-sync's own block-height gauges. The first row whose
# `lag_blocks` is <= 1 is the answer — read it off the table.
set -uo pipefail
cd "$(dirname "$0")"

OUT=measurements.md
CID=$(docker compose ps -q cardano-db-sync)
if [[ -z ${CID} ]]; then echo "cardano-db-sync container not found — ./run.sh first" >&2; exit 1; fi

psql()    { docker compose exec -T postgres psql -U postgres -d cexplorer -At -F' | ' "$@" 2>&1; }
dbs()     { docker compose exec -T cardano-db-sync "$@" 2>&1; }
gauge()   { awk -v k="$1" '$1==k {print $2}' <<<"${METRICS}"; }

NOW_EPOCH=$(date -u +%s)
NOW=$(date -u +%FT%TZ)
STARTED=$(docker inspect -f '{{.State.StartedAt}}' "${CID}")
# BSD date (macOS) — StartedAt has nanoseconds, which %S will not take.
STARTED_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${STARTED%.*}" +%s 2>/dev/null \
                || date -u -d "${STARTED}" +%s)
ELAPSED=$(( NOW_EPOCH - STARTED_EPOCH ))

METRICS=$(dbs curl -sf localhost:8080/ | grep -v '^#')
DB_H=$(gauge cardano_db_sync_db_block_height)
NODE_H=$(gauge cardano_db_sync_node_block_height)
LAG=$([[ -n ${DB_H:-} && -n ${NODE_H:-} ]] && echo $(( ${NODE_H%.*} - ${DB_H%.*} )) || echo "n/a")
TIP=$([[ ${LAG} != "n/a" && ${LAG} -le 1 ]] && echo "**AT TIP**" || echo "syncing")

# cgroup v2 memory.peak is what the kernel enforces the 6144M limit against (anon + page cache),
# so it is the figure that decides the Pi's memory limit. memory.stat's `anon` is the true-RSS
# comparison. Fall back to cgroup v1, then to docker stats' instantaneous value.
PEAK=$(dbs cat /sys/fs/cgroup/memory.peak)
[[ ${PEAK} =~ ^[0-9]+$ ]] || PEAK=$(dbs cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes)
[[ ${PEAK} =~ ^[0-9]+$ ]] || PEAK="n/a (docker stats now: $(docker stats --no-stream --format '{{.MemUsage}}' "${CID}"))"
ANON=$(dbs sh -c "awk '\$1==\"anon\"{print \$2}' /sys/fs/cgroup/memory.stat")

{
  echo
  echo "## ${NOW}  —  elapsed ${ELAPSED}s ($(( ELAPSED / 3600 ))h), ${TIP}"
  echo
  echo '| field | value |'
  echo '|---|---|'
  echo "| elapsed since db-sync start | ${ELAPSED} s |"
  echo "| db_block_height | ${DB_H:-n/a} |"
  echo "| node_block_height | ${NODE_H:-n/a} |"
  echo "| lag_blocks | ${LAG} |"
  echo "| db_slot_height | $(gauge cardano_db_sync_db_slot_height) |"
  echo "| db_queue_length | $(gauge cardano_db_sync_db_queue_length) |"
  echo "| epoch_sync_number | $(gauge cardano_db_sync_db_epoch_sync_number) |"
  echo "| epoch_sync_duration_seconds | $(gauge cardano_db_sync_db_epoch_sync_duration_seconds) |"
  echo "| cgroup memory.peak (bytes) | ${PEAK} |"
  echo "| cgroup memory.stat anon (bytes) | ${ANON} |"
  echo "| db-sync RestartCount / OOMKilled | $(docker inspect -f '{{.RestartCount}} / {{.State.OOMKilled}}' "${CID}") |"
  echo "| pg_database_size(cexplorer) | $(psql -c "SELECT pg_size_pretty(pg_database_size('cexplorer'))") |"
  echo "| db-sync state dir | $(dbs du -sh /var/lib/cexplorer | cut -f1) |"
  echo "| node chain db | $(docker compose exec -T cardano-node du -sh /data/db 2>&1 | cut -f1) |"
  echo
  echo '### Probes — do the options do what D-4/D-5 claim?'
  echo
  echo '```'
  psql -c "
    SELECT 'stake_deregistration', count(*) FROM stake_deregistration
    UNION ALL SELECT 'pool_update',               count(*) FROM pool_update
    UNION ALL SELECT 'drep_distr',                count(*) FROM drep_distr
    UNION ALL SELECT 'off_chain_vote_data',       count(*) FROM off_chain_vote_data
    UNION ALL SELECT 'off_chain_vote_fetch_error',count(*) FROM off_chain_vote_fetch_error
    UNION ALL SELECT 'voting_anchor',             count(*) FROM voting_anchor
    UNION ALL SELECT 'drep_distr max epoch_no',   max(epoch_no) FROM drep_distr"
  echo '```'
  echo
  echo '### pg_total_relation_size, top 20 (hardware-independent: this is the PVC answer)'
  echo
  echo '```'
  psql -c "
    SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid)), pg_total_relation_size(c.oid)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20"
  echo '```'
  echo
  echo '### db-sync log, last 5 lines'
  echo
  echo '```'
  docker compose logs --no-log-prefix --tail 5 cardano-db-sync 2>&1
  echo '```'
} >> "${OUT}"

echo "appended to ${OUT}: elapsed ${ELAPSED}s, lag_blocks ${LAG}, ${TIP}"
