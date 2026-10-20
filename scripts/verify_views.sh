#!/usr/bin/env bash
# Run every sql/checks/*.sql against a synced db-sync, in lexical order, and stop on the first
# failed assertion.
#
# NEVER --single-transaction: a later check ends with a bare REFRESH MATERIALIZED VIEW
# CONCURRENTLY, which PostgreSQL forbids inside a transaction block.
#
# Usage: PG_CONN_STR="host=... dbname=cexplorer user=..." scripts/verify_views.sh [check.sql ...]
set -euo pipefail

: "${PG_CONN_STR:?set PG_CONN_STR to the db-sync database, e.g. \"host=localhost dbname=cexplorer user=postgres\"}"

cd "$(dirname "$0")/.."
checks=("$@")
if [ ${#checks[@]} -eq 0 ]; then
  shopt -s nullglob
  checks=(sql/checks/*.sql)
fi

if [ ${#checks[@]} -eq 0 ]; then
  echo "no checks found under sql/checks/" >&2
  exit 1
fi

for f in "${checks[@]}"; do
  echo "== $f"
  psql "$PG_CONN_STR" -v ON_ERROR_STOP=1 -q -f "$f"
done
echo "all ${#checks[@]} check file(s) passed"
