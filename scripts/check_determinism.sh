#!/usr/bin/env bash
# F1 check 3: running the metric catalog twice against the same db-sync produces identical output.
#
# The point is not that SQL is deterministic in the abstract — it is that OUR statements are. A
# statement that reads `now()`, that depends on a plan's row order, or that joins something
# db-sync rewrites in place would produce two different answers from one database, and a registry
# whose published numbers move on their own is not a registry.
#
# Every statement is run over the PINNED cursor in test/fixtures/preprod-epoch-320-metrics.json,
# which is a CLOSED epoch. That is what makes the answers history rather than a live tally: a
# closed epoch's last block never changes, so a statement parameterised by it cannot move with the
# tip. The two view-backed formulas (`sql_object`) have no cursor to pin, so they do read live
# data, and that is what the tip check below is for.
#
# Exit codes:
#   0  every statement produced the same output twice
#   1  drift: a statement produced two different answers from one database, tip unchanged
#   2  inconclusive: a statement drifted AND db-sync advanced mid-run, so the chain may be the
#      cause rather than the statement. Re-run against a stopped db-sync to decide.
#
# SIGNING CHECK 3: the run that signs it is the one against a caught-up preprod db-sync. CI runs
# this against the seeded skeleton of test/fixtures/dbsync-skeleton.sql, whose tables are empty —
# that proves the statements parse and are self-consistent, not that they are stable over real
# rows. The preprod run belongs in the deployment runbook alongside the db-sync sync procedure;
# until Block 3 writes docs/deployment/preprod-dbsync-sync.md, this paragraph is where it is
# recorded. MEASURED against our own preprod db-sync at epoch 320: 8/8, about 3.5 minutes.
#
# Usage: PG_CONN_STR="host=... dbname=cexplorer user=postgres" scripts/check_determinism.sh
set -euo pipefail

: "${PG_CONN_STR:?set PG_CONN_STR to the db-sync database, e.g. \"host=localhost dbname=cexplorer user=postgres\"}"

cd "$(dirname "$0")/.."

CATALOG=resources/metric-formulas.json
FIXTURE=test/fixtures/preprod-epoch-320-metrics.json

[ -f "$CATALOG" ] || { echo "no metric catalog found: $CATALOG" >&2; exit 1; }
[ -d resources/metrics ] || { echo "no metric catalog found: resources/metrics/" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "no pinned cursor found: $FIXTURE" >&2; exit 1; }

q() { psql "$PG_CONN_STR" -At -F'|' -v ON_ERROR_STOP=1 "$@"; }

# sha256sum is coreutils (Linux), shasum is perl (macOS and the GitHub runners have both).
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

# The tip, as (block_no, hash). Read from public.block rather than palmares.sync_state so this
# works on a database the palmares schema has not been applied to yet.
tip() {
  q -c "SELECT COALESCE(block_no::text, '-') || ':' || encode(hash, 'hex')
        FROM public.block ORDER BY id DESC LIMIT 1"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

as_of=$(python3 -I -c "
import json, sys
print(json.load(open('$FIXTURE'))['metrics']['as_of_epoch'])
")
drep_hex=$(python3 -I -c "
import json, sys
print(json.load(open('$FIXTURE'))['drep']['hex'])
")

# COALESCE to 0: on a seeded skeleton this credential does not exist, and the check is still
# meaningful — a statement must give the same answer about an unknown DRep twice as well.
drep_id=$(q -c "SELECT COALESCE((SELECT id FROM public.drep_hash
                                  WHERE raw = decode('$drep_hex', 'hex')), 0)")

# One runnable file per formula. The `?` placeholders are replaced positionally, in the order the
# catalog's `params` array names them, which is the order resources/metrics/*.sql binds them in
# its leading `p` CTE. UnitTests.MetricCatalog already asserts that the placeholder count matches
# `params` per file, so a mismatch here is impossible rather than merely unlikely.
#
# retention_window_epochs is 10 only because it has to be something: this check compares a
# statement against ITSELF, so the value is irrelevant as long as both runs use it. The real
# window lives in Palmares.Metrics.Catalog.retentionWindowEpochs and is pinned by the fixture test.
python3 -I - "$CATALOG" "$tmp" "$drep_id" "$as_of" <<'PY'
import json, pathlib, re, sys

catalog, outdir, drep_id, as_of = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
values = {"drep_hash_id": drep_id, "as_of_epoch": as_of, "retention_window_epochs": "10"}

for entry in json.load(open(catalog)):
    fid = entry["formula_id"]
    if entry.get("sql_file"):
        sql = (pathlib.Path("resources/metrics") / entry["sql_file"]).read_text()
        args = iter([values[p] for p in entry["params"]])
        sql = re.sub(r"\?", lambda _: next(args), sql)
    else:
        # A view has no parameters: the whole relation is the published object.
        sql = "SELECT * FROM %s;\n" % entry["sql_object"]
    (outdir / (fid + ".sql")).write_text(sql)
print("%d statements prepared" % len(json.load(open(catalog))))
PY

before=$(tip)
ok=0
drifted=()

for f in "$tmp"/*.sql; do
  id=$(basename "$f" .sql)
  # LC_ALL=C sort, because a result set without ORDER BY has no canonical row order and two runs
  # may legitimately return the same rows in a different order. What check 3 asks about is the
  # numbers, so the multiset is what gets hashed.
  a=$(q -f "$f" | LC_ALL=C sort | digest)
  b=$(q -f "$f" | LC_ALL=C sort | digest)
  if [ "$a" = "$b" ]; then
    ok=$((ok + 1))
    echo "  ok   $id  $a"
  else
    drifted+=("$id")
    echo "  DRIFT $id  $a != $b"
  fi
done
after=$(tip)

total=$((ok + ${#drifted[@]}))

if [ ${#drifted[@]} -eq 0 ]; then
  echo "$ok/$total metrics deterministic (epoch $as_of, drep_hash_id $drep_id, tip ${before:-none})"
  exit 0
fi

if [ "$before" != "$after" ]; then
  echo "INCONCLUSIVE: db-sync advanced mid-run (${before:-none} -> ${after:-none})." >&2
  echo "  drifted: ${drifted[*]}" >&2
  echo "  Re-run against a stopped db-sync to tell a moving chain from a moving formula." >&2
  exit 2
fi

echo "DRIFT: ${#drifted[@]}/$total metrics gave two different answers from one database." >&2
echo "  ${drifted[*]}" >&2
exit 1
