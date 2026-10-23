#!/usr/bin/env bash
# Post-deploy check: query-api really owns the `palmares` schema lifecycle.
#
# query-api applies sql/000..030 at boot, in one transaction, and dies if any of it fails
# (Query.Views). This script verifies the RESULT of that against a running stack — the schema is
# there, complete, and its one matview is being refreshed.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO: boot the binary to prove it dies on a broken DDL
# file, which is how the plan drafted check 3. Booting query-api needs an Atlas provider config
# and a provider key, neither of which belongs in a schema check, and the behaviour is already
# pinned where it can be: UnitTests.Views asserts that a failing statement anywhere in the set
# rolls the whole set back and leaves the previous schema serving, and applyPalmaresSchema's
# `die` is what turns that into a refused boot. This script answers the question those tests
# cannot: did the deployed process actually do it.
#
# Usage:
#   PG_CONN_STR="host=... dbname=cexplorer user=postgres" scripts/smoke_views.sh [--watch-refresh]
#
# --watch-refresh adds one PALMARES_VIEW_REFRESH_SECONDS + 30 wait and asserts the matview was
# rewritten in that window. Off by default because the default interval is five minutes.
set -euo pipefail

: "${PG_CONN_STR:?set PG_CONN_STR to the db-sync database, e.g. \"host=localhost dbname=cexplorer user=postgres\"}"

psql_at() { psql "$PG_CONN_STR" -At -v ON_ERROR_STOP=1 -c "$1"; }

expect() {
  local what="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $what: $got"
  else
    echo "  FAIL $what: expected $want, got $got" >&2
    exit 1
  fi
}

# 1. A boot recreates the whole schema. The counts are the deliverable of the SQL block: nineteen
#    plain views, the one materialized view, and the one function.
#
#    Nineteen, not the eighteen the plan's table listed: palmares.cc_cold_interval was factored
#    out of palmares.vote so that the committee hot-to-cold mapping has ONE definition, which two
#    objects now use. See its own comment for the 87s-to-2s measurement that forced it.
expect "plain views" 19 "$(psql_at "SELECT count(*) FROM pg_views WHERE schemaname = 'palmares'")"
expect "materialized views" 1 "$(psql_at "SELECT count(*) FROM pg_matviews WHERE schemaname = 'palmares'")"
expect "functions" 1 "$(psql_at "SELECT count(*) FROM pg_proc p
                                  JOIN pg_namespace n ON n.oid = p.pronamespace
                                  WHERE n.nspname = 'palmares' AND p.proname = 'eligible_actions'")"

# 2. The matview must be POPULATED and carry its unique index. Either missing and the refresh
#    thread fails at runtime rather than at boot, which is the failure mode this check exists for:
#    a never-populated matview rejects REFRESH ... CONCURRENTLY, and CONCURRENTLY without a unique
#    index is rejected outright.
expect "drep_metrics is populated" "t" \
  "$(psql_at "SELECT ispopulated FROM pg_matviews WHERE schemaname = 'palmares' AND matviewname = 'drep_metrics'")"
expect "drep_metrics unique index" 1 \
  "$(psql_at "SELECT count(*) FROM pg_indexes
               WHERE schemaname = 'palmares' AND indexname = 'palmares_idx_drep_metrics_pk'")"
expect "drep_metrics row count matches drep_hash" "$(psql_at "SELECT count(*) FROM public.drep_hash WHERE raw IS NOT NULL")" \
  "$(psql_at "SELECT count(*) FROM palmares.drep_metrics")"

if [ "${1:-}" = "--watch-refresh" ]; then
  # A REFRESH rewrites every row, so n_tup_ins for the matview strictly increases across one
  # interval. This is the only observation that distinguishes "the thread is running" from "the
  # schema was applied once and the thread died".
  interval="${PALMARES_VIEW_REFRESH_SECONDS:-300}"
  ins() { psql_at "SELECT n_tup_ins FROM pg_stat_all_tables
                    WHERE schemaname = 'palmares' AND relname = 'drep_metrics'"; }
  before=$(ins)
  echo "  .... waiting $((interval + 30))s for a refresh tick (n_tup_ins = $before)"
  sleep $((interval + 30))
  after=$(ins)
  if [ "$after" -gt "$before" ]; then
    echo "  ok   refresh tick observed: $before -> $after rows inserted"
  else
    echo "  FAIL no refresh within one interval ($before -> $after)." >&2
    echo "       Either the thread died or the tip has not moved; check query-api's stderr for" >&2
    echo "       '[refresh]' lines — it logs and keeps looping rather than exiting." >&2
    exit 1
  fi
else
  echo "  skip refresh tick (pass --watch-refresh to wait one interval and assert it)"
fi

echo "views OK"
