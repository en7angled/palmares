#!/usr/bin/env bash
# Substrate sizing for ADR 0001. Everything that ADR asserts must come out of THIS SCRIPT, not out
# of a note — otherwise the numbers age silently and the PVC decision rests on a figure nobody can
# reproduce.
#
# It runs against either target, because the two exist at different times:
#
#   * Experiment A, off-cluster, which is what sized the ADR (and is what exists today):
#       PSQL='docker exec -i palmares-dbsync-exp-postgres-1 psql -U postgres -d cexplorer' \
#       CONTAINERS='palmares-dbsync-exp-postgres-1 palmares-dbsync-exp-cardano-db-sync-1 palmares-dbsync-exp-cardano-node-1' \
#       scripts/measure_substrate.sh
#
#   * the cluster, once T-SUBSTRATE-3/4 have landed (the default):
#       scripts/measure_substrate.sh
#
# The database and relation sizes are CHAIN facts and transfer between hosts unchanged. The memory
# figures are HOST facts and do not: they say what the process used under the cap it was given, and
# the cap is part of the reading. ADR 0001 says which is which.
set -euo pipefail

: "${PSQL:=kubectl --context minirack-lan -n cardano-preprod exec -i deploy/deployment-palmares-postgres -- psql -U dbsync -d cexplorer}"
: "${K:=kubectl --context minirack-lan -n cardano-preprod}"
# Space-separated. Empty means "use $K exec", i.e. the cluster.
: "${CONTAINERS:=}"

run_psql() { $PSQL "$@"; }

echo "# Substrate measurement — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# Precondition. Measuring a mid-sync database produces numbers the ADR would then assert as final,
# and a half-synced `block` table is the single most misleading figure in the whole set.
echo '## tip'
run_psql -At -c "SELECT 'epoch='||max(epoch_no)||' slot='||max(slot_no)||' block='||max(block_no) FROM public.block;"
run_psql -At -c "
SELECT CASE WHEN extract(epoch from now() - max(time)) < 600
            THEN 'at tip (lag '||round(extract(epoch from now() - max(time)))||'s) — numbers are final'
            ELSE 'NOT AT TIP (lag '||round(extract(epoch from now() - max(time)))||'s) — numbers are NOT final'
       END FROM public.block;"
echo

echo '## database size'
run_psql -At -c "SELECT 'pg_database_size = '||pg_size_pretty(pg_database_size('cexplorer'))||' ('||pg_database_size('cexplorer')||' bytes)';"
echo

echo '## top 20 relations by total size, schema public'
run_psql -c "SELECT relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
    pg_size_pretty(pg_relation_size(c.oid)) AS heap,
    pg_size_pretty(pg_indexes_size(c.oid)) AS indexes
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
  ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 20;"

echo '## our own schema, which adds no projection tables'
run_psql -c "SELECT n.nspname AS schema, count(*) FILTER (WHERE c.relkind = 'r') AS tables,
    count(*) FILTER (WHERE c.relkind = 'v') AS views,
    count(*) FILTER (WHERE c.relkind = 'm') AS matviews,
    pg_size_pretty(coalesce(sum(pg_total_relation_size(c.oid)), 0)) AS total
  FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace = n.oid
  WHERE n.nspname LIKE 'palmares%' GROUP BY n.nspname ORDER BY n.nspname;"

echo '## the governance volume the product actually reads'
run_psql -c "SELECT
    (SELECT count(*) FROM public.gov_action_proposal) AS gov_actions,
    (SELECT count(*) FROM public.voting_procedure) AS votes,
    (SELECT count(*) FROM public.voting_procedure WHERE voter_role = 'ConstitutionalCommittee') AS cc_votes,
    (SELECT count(*) FROM public.drep_hash) AS drep_hashes,
    (SELECT count(*) FROM public.delegation_vote) AS vote_delegations,
    (SELECT count(*) FROM public.drep_distr) AS drep_distr_rows,
    (SELECT count(*) FROM public.treasury_withdrawal) AS withdrawals;"

echo '## epoch_stake — inserted unconditionally with the ledger, unused by this product'
run_psql -c "SELECT count(*) AS rows,
    pg_size_pretty(pg_total_relation_size('public.epoch_stake')) AS total,
    round(100.0 * pg_total_relation_size('public.epoch_stake') / pg_database_size('cexplorer'), 1) AS pct_of_db
  FROM public.epoch_stake;"

echo '## anchor coverage — preprod test anchors mostly point at dead URLs'
run_psql -c "SELECT
    (SELECT count(*) FROM public.off_chain_vote_data) AS resolved,
    (SELECT count(*) FROM public.off_chain_vote_fetch_error) AS fetch_errors;"

echo '## the shelley flip — these are empty if `shelley: enable` was not set before the first sync'
run_psql -c "SELECT
    (SELECT count(*) FROM public.stake_deregistration) AS stake_deregistration,
    (SELECT count(*) FROM public.pool_update) AS pool_update;"

# ---------------------------------------------------------------------------------------------
# Host facts. These say what each process used UNDER THE CAP IT WAS GIVEN, and the cap is part of
# the reading — GHC's RTS sizes its heap from /proc/meminfo rather than from the cgroup limit, so a
# db-sync that reached its cap tells you the ceiling held, not what the live set is. ADR 0001's
# "What the memory number does and does not establish" is the whole point.
# ---------------------------------------------------------------------------------------------
echo
echo '## memory and disk, per container'
if [ -n "$CONTAINERS" ]; then
  for c in $CONTAINERS; do
    echo "--- $c"
    docker exec "$c" sh -c '
      cat /sys/fs/cgroup/memory.peak 2>/dev/null | awk "{printf \"memory.peak      = %.2f GiB\n\", \$1/1073741824}"
      cat /sys/fs/cgroup/memory.max  2>/dev/null | awk "{ if (\$1 == \"max\") print \"memory.max       = unlimited\"; else printf \"memory.max       = %.2f GiB\n\", \$1/1073741824 }"
      awk "/^anon /{printf \"memory.stat anon = %.2f GiB\n\", \$2/1073741824} /^file /{printf \"memory.stat file = %.2f GiB\n\", \$2/1073741824}" /sys/fs/cgroup/memory.stat 2>/dev/null
      awk "/^max /{print \"reclaim at max   = \" \$2 \" events\"} /^oom_kill /{print \"oom_kill         = \" \$2}" /sys/fs/cgroup/memory.events 2>/dev/null
    ' 2>/dev/null || echo "  (cgroup v2 figures unavailable)"
    docker exec "$c" du -sh /var/lib/postgresql/data /var/lib/cexplorer /data/db 2>/dev/null | sed 's/^/  du  /' || true
  done
else
  $K exec deploy/deployment-palmares-postgres -- df -h /var/lib/postgresql/data | tail -1
  $K exec deploy/deployment-palmares-dbsync -- sh -c \
    'cat /sys/fs/cgroup/memory.peak 2>/dev/null || cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes' \
    || echo 'peak_rss unavailable — use Experiment A'
  $K top pod --no-headers 2>/dev/null || echo 'metrics-server unavailable'
fi

echo
echo '## docker volumes (Experiment A only)'
docker system df -v 2>/dev/null | awk '/VOLUME NAME/{p=1} p && /dbsync-exp/{print "  " $0}' || true

echo
echo 'Done. ADR 0001 carries the verdicts; this script carries the numbers.'
