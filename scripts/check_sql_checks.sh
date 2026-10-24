#!/usr/bin/env bash
# GV-25: every file in sql/checks/ is executed by CI, against the seeded db-sync skeleton.
#
# WHY THIS EXISTS. The seven check files are the authority on view correctness — 135 ASSERTs over
# a caught-up preprod db-sync — and nothing ran them automatically, so the only thing standing
# between a renamed column in `sql/020_views.sql` and a check file that no longer resolves was
# somebody remembering to run `psql -f` by hand. That is the failure this closes: the files are
# code, and code nothing executes rots.
#
# WHAT IT CAN PROVE HERE, AND WHAT IT CANNOT. CI has no synced db-sync — building one takes about
# seven hours — so the checks run against `test/fixtures/dbsync-skeleton.sql` plus the palmares
# schema, with every table EMPTY. On empty tables the magnitude assertions are false by
# construction (`count(DISTINCT cert_kind) = 3` is `0 = 3`), and plpgsql aborts the whole DO block
# at the first one: measured, `010_drep.sql` died at its sixth ASSERT of fifteen and the other six
# files died earlier still, so a plain run proves almost nothing about the remaining ~130.
#
# `SET plpgsql.check_asserts = off` is not the answer either. It skips the ASSERT statement whole,
# condition included — measured: a reference to a column that does not exist inside an ASSERT
# condition is never resolved and the block runs to the end — and the conditions are where
# essentially all of the SQL lives.
#
# So each ASSERT's condition is rewritten to `TRUE OR <condition>`. PostgreSQL parses and ANALYSES
# the whole expression before it constant-folds the OR away, so every relation, column, function,
# cast and type in the condition is still resolved, while the result is TRUE and the block runs to
# its final RAISE NOTICE. That is the signal: all seven files execute end to end, every identifier
# in all 135 conditions is checked against the real schema, and a renamed column fails here.
# MEASURED against a planted rename (`registration_status` -> `reg_status` throughout
# `010_drep.sql`): ERROR, column "reg_status" does not exist. The self-test at the bottom plants the
# same defect in its smallest form on every run, because a gate that cannot fail is not a gate.
#
# It still cannot catch anything that needs ROWS: a wrong number, a join that fans out, a status
# partition that is no longer total, a duplicate activity cursor, a formula that disagrees with the
# matview. Those are what the preprod run is for, and the preprod run is the one that SIGNS these
# checks. Until the deployment runbook carries it, this paragraph is where it is recorded — the
# command is the originals, unmodified, against the synced database:
#
#   for f in sql/checks/*.sql; do
#     psql "host=... dbname=cexplorer user=postgres" -v ON_ERROR_STOP=1 -f "$f"
#   done
#
# MEASURED 2026-10-24 against our own preprod db-sync at tip epoch 321: 7/7 pass. 010-060 were run
# read-only; `070_drep_metrics.sql`'s DO block was run in a session with
# `default_transaction_read_only = on`, which passed and then refused the file's trailing
# `REFRESH MATERIALIZED VIEW CONCURRENTLY` — the only write in the directory.
#
# Usage: PG_CONN_STR="host=localhost user=postgres dbname=postgres" scripts/check_sql_checks.sh
#
# Expects the skeleton and sql/000..030 already applied to that database, which is exactly what the
# `determinism` job's earlier step does — hence this runs there rather than in a job of its own.
set -euo pipefail

: "${PG_CONN_STR:?set PG_CONN_STR to a database holding the db-sync skeleton and the palmares schema}"

cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Rewrite every ASSERT condition, then refuse to continue if one escaped the rewrite. The anchored
# form is what the files use today (measured: 135 of 135 ASSERT statements sit at the start of a
# line, and the only other occurrences of the word are prose inside `--` comments). An ASSERT
# written mid-line, or with its condition on the following line, would be left alone by the sed and
# would then abort the block on empty data — which would look like a failing check rather than a
# gate that had quietly stopped covering one assertion. So it is an error here instead.
prepare() {
  local src=$1 out=$2 leftover
  sed -E 's/^([[:space:]]*)ASSERT /\1ASSERT TRUE OR /' "$src" > "$out"
  leftover=$(grep -nE 'ASSERT([[:space:]]|$)' "$out" \
             | grep -vE '^[0-9]+:[[:space:]]*--' \
             | grep -vE 'ASSERT TRUE OR ' || true)
  if [ -n "$leftover" ]; then
    echo "check_sql_checks: an ASSERT in $src escaped the TRUE OR rewrite, so its condition would" >&2
    echo "  not be checked. Put the ASSERT and the start of its condition on one line." >&2
    echo "$leftover" >&2
    exit 1
  fi
}

# `-q` so a clean run says nothing but the NOTICEs; ON_ERROR_STOP so the first unresolved
# identifier is the exit code and not a line in a log nobody reads.
run() { psql "$PG_CONN_STR" -v ON_ERROR_STOP=1 -q -f "$1"; }

files=(sql/checks/*.sql)
[ ${#files[@]} -gt 0 ] || { echo "check_sql_checks: no files in sql/checks/" >&2; exit 1; }

failed=()
for f in "${files[@]}"; do
  n=$(basename "$f")
  prepare "$f" "$tmp/$n"
  echo "---- $n"
  if run "$tmp/$n"; then
    echo "  ok   $n ($(grep -cE '^[[:space:]]*ASSERT ' "$f") assertions resolved against the schema)"
  else
    failed+=("$n")
    echo "  FAIL $n" >&2
  fi
done

# The self-test, same shape as scripts/check_gitleaks_allowlist.sh: plant the defect this gate
# exists for and require it to be caught. It asserts the one property everything above rests on —
# that `TRUE OR` keeps the condition ANALYSED rather than skipping it, the way
# `plpgsql.check_asserts = off` does. If that ever stopped holding, all seven files would still run
# clean and the gate would be checking nothing at all.
cat > "$tmp/selftest.sql" <<'SQL'
DO $$ BEGIN
  ASSERT TRUE OR (SELECT count(*) FROM palmares.drep WHERE no_such_column = 1) = 0, 'planted';
END $$;
SQL
if run "$tmp/selftest.sql" >/dev/null 2>&1; then
  echo "check_sql_checks: a column that does not exist inside a rewritten ASSERT was NOT caught," >&2
  echo "  so the rewrite is skipping conditions rather than analysing them. This gate proves nothing." >&2
  exit 1
fi
echo "---- self-test: an unresolvable column inside a rewritten ASSERT is caught"

if [ ${#failed[@]} -gt 0 ]; then
  echo "check_sql_checks: ${#failed[@]} of ${#files[@]} check files do not resolve against the schema:" >&2
  echo "  ${failed[*]}" >&2
  echo "  An identifier a check names is gone or renamed. Fix the check, or the view it reads." >&2
  exit 1
fi

echo "check_sql_checks: OK — ${#files[@]} check files execute end to end against the empty skeleton"
echo "  (structure only: no rows, so no magnitude, cardinality or partition assertion was tested)"
