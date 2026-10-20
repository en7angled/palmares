#!/usr/bin/env bash
# F1 check 12's smoke half: the query API answered, with the values a client depends on.
#
# Every later route family appends a section. The assertions are deliberately about VALUES and
# not just status codes — a 200 carrying the wrong number is the failure this registry has to
# avoid, and a smoke test that only checks codes would pass through it.
#
# Where a figure is preprod's own, it is marked. Those are the ones to re-measure rather than
# edit blindly if the chain moves.
#
# Usage: PALMARES_API=http://localhost:8083 scripts/smoke_query_api.sh
set -euo pipefail

API="${PALMARES_API:-http://localhost:8083}"
fail=0

# 2xx only: -f makes curl fail on a 4xx so a wrong status cannot read as a wrong value.
j() { curl -fsS -H 'Accept: application/json' "$API$1" | jq -c "$2"; }

# `|| true`: without it `set -e` aborts the whole run on the first failing assertion instead of
# recording it and carrying on, which is the difference between one finding and a full report.
assert() {
  got=$(j "$1" "$2" || true)
  if [ "$got" = "$3" ]; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2 => $got (want $3)"; fail=1; fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$API$1"; }

# Error bodies need a NON-failing curl: -f discards the body of a 4xx, so `assert` could never
# see `.code`.
jerr() { curl -sS -H 'Accept: application/json' "$API$1" | jq -c "$2"; }
assert_err() {
  got=$(jerr "$1" "$2" || true)
  if [ "$got" = "$3" ]; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2 => $got (want $3)"; fail=1; fi
}

has_header() {
  if curl -fsS -D- -o /dev/null "$API$1" | grep -qi "^$2:"; then
    echo "  ok   $1 sends $2"
  else
    echo "  FAIL $1 is missing $2"
    fail=1
  fi
}

echo "== probes, status, freshness (T-API-6)"
assert /health '.status' '"healthy"'
assert /health '.service' '"query-api"'
[ "$(code /ready)" = 200 ] && echo "  ok   /ready is 200" || { echo "  FAIL /ready is $(code /ready)"; fail=1; }
assert /ready '.status' '"ready"'
assert /status '.network' '"preprod"'
assert /status '.governance.source' '"cardano-db-sync"'
assert /status '.governance.is_ready' 'true'
assert '/status' '.governance.epoch >= 320' 'true'
# Spec check A1, read from /status rather than from the probe: the probe only says red/not-red.
assert '/status' '.governance.lag_seconds < 120' 'true'
# preprod's own value. This is the PARAMETER, not the voting window: the ledger sets
# expiration = proposed_epoch + lifetime + 1, so the observed delta on all 131 actions is 7.
assert /status '.epoch_params.gov_action_lifetime' '6'
assert /status '.epoch_params.drep_activity' '20'
assert /status '.epoch_params.committee_min_size' '3'
assert /status '.epoch_params.pool_thresholds | map(.[0]) | sort' \
  '["pvt_committee_no_confidence","pvt_committee_normal","pvt_hard_fork_initiation","pvt_motion_no_confidence","pvtpp_security_group"]'
assert /status '.epoch_params.drep_thresholds | length' '10'
# Every threshold must carry a number. A null here means db-sync has no ledger state, which makes
# every tally we publish unauditable while the endpoint still looks healthy.
assert /status '[.epoch_params.drep_thresholds, .epoch_params.pool_thresholds] | flatten(1) | map(.[1]) | map(type) | unique' \
  '["number"]'

has_header /status 'x-chain-epoch'
has_header /status 'x-chain-slot'
has_header /status 'x-chain-block-time'
has_header /status 'x-data-lag-seconds'
has_header /status 'x-data-source'
# The headers are useless to a browser unless CORS exposes them, and a missing expose list fails
# silently: the server sends the header, fetch() cannot read it, and nothing logs an error.
if curl -fsS -D- -o /dev/null -H 'Origin: https://gov.cardano.vip' "$API/status" \
  | grep -i '^access-control-expose-headers:' | grep -qi 'x-chain-epoch'; then
  echo "  ok   freshness headers are exposed to the browser"
else
  echo "  FAIL x-chain-epoch is not in access-control-expose-headers"
  echo "       (set CORS_ALLOWED_ORIGINS=https://gov.cardano.vip for this check to apply)"
  fail=1
fi

echo "== metric formulas (T-API-7)"
assert /metrics/formulas 'length' '8'
assert /metrics/formulas '[.[].formula_id] | sort' \
  '["age_days_v1","delegator_retention_rate_v1","gov_action_state_v1","participation_rate_v1","rationale_rate_v1","tally_cast_votes_v1","vote_latency_median_hours_v1","votes_by_type_v1"]'
# D-9: the statement the server runs IS the statement the endpoint publishes. Six carry one.
assert /metrics/formulas '[.[] | select(.sql != null)] | length' '6'
# Exactly one of sql_file / sql_object per formula, so every id resolves to something readable.
assert /metrics/formulas '[.[] | ((.sql_file != null) != (.sql_object != null))] | unique' '[true]'
# The published SQL must be the real statement, not a stub: its own leading CTE must be there.
assert /metrics/formulas '[.[] | select(.formula_id == "participation_rate_v1") | .sql | contains("palmares.eligible_actions")]' '[true]'
assert /metrics/formulas '[.[] | select(.formula_id=="participation_rate_v1")][0] | [.field, .null_when, .version]' \
  '["participation_rate","eligible_actions = 0",1]'
# The window is a BOUND parameter, never a literal in the statement.
assert /metrics/formulas '[.[] | select(.formula_id=="delegator_retention_rate_v1")][0].params' \
  '["drep_hash_id","as_of_epoch","retention_window_epochs"]'

echo "== dreps (T-API-8)"
# preprod's own figures. 294 registered + 511 retired + 7 never-registered credentials; the
# never-registered ones are not DReps and must never be listed, which is why 294 and not 301.
assert '/dreps?limit=1' '.total' '294'
assert '/dreps?limit=1&status=retired' '.total' '511'
assert '/dreps?limit=1' '.limit' '1'
# clamped silently, and the APPLIED value is echoed so a client can see what it got
assert '/dreps?limit=999' '[.limit, (.items|length)]' '[200,200]'
[ "$(code '/dreps?offset=10001')" = 400 ] && echo "  ok   /dreps offset ceiling is 400" || { echo "  FAIL offset ceiling"; fail=1; }
assert_err '/dreps?offset=10001' '.code' '"offset_too_large"'
# the two reserved ledger options are never in the list: they hold stake but no credential
assert '/dreps?limit=200' '[.items[].id] | map(select(startswith("drep_always"))) | length' '0'
# default ordering is voting_power descending -- this list is what a delegator chooses from
assert '/dreps?limit=5' '[.items[].voting_power] | . == (. | sort | reverse)' 'true'
# ascending puts the powerless first. They are 0 and not null: the ledger's distribution for an
# epoch simply does not include them, which is zero power FOR THAT EPOCH, not unknown power.
# Measured: 109 of the 294 registered DReps, 8 of them with live delegations whose stake arrives
# in the next epoch's snapshot.
assert '/dreps?order_by=voting_power&sort_order=asc&limit=3' '[.items[].voting_power] | unique' '[0]'
# the fixture DRep, found by name through the trigram index
assert '/dreps?q=Bitcows' '[.total, (.items|length)]' '[1,1]'
assert '/dreps?q=Bitcows' '.items[0].id' '"drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"'
assert '/dreps?q=Bitcows' '.items[0].given_name' '"Bitcows"'
# INVARIANTS rather than magnitudes, because eligible_actions grows every time an action settles
# and voting_power changes every epoch. The magnitudes are pinned at a CLOSED epoch in
# test/fixtures/preprod-epoch-320-metrics.json, which is where a pin can be stable.
assert '/dreps?q=Bitcows' '.items[0] | [(.eligible_actions >= 114), (.votes_cast >= 16), (.votes_cast <= .eligible_actions)]' '[true,true,true]'
assert '/dreps?q=Bitcows' '.items[0] | (.participation_rate * 1000000 | round) == ((.votes_cast / .eligible_actions) * 1000000 | round)' 'true'
assert '/dreps?q=Bitcows' '.items[0] | [.voting_power_epoch == .as_of_epoch, .active_until_epoch > .as_of_epoch]' '[true,true]'
assert '/dreps?q=Bitcows' '.items[0].age_days | . >= 733' 'true'
# a filter that matches few rows: the total comes from the same WHERE as the page (F-17)
assert '/dreps?status=retired&limit=5' '(.items | length) <= 5 and (.total >= (.items|length))' 'true'
assert '/dreps?min_participation_rate=1.1' '[.total, (.items|length)]' '[0,0]'
# age_days is null exactly when registered_at is null (D-17)
assert '/dreps?limit=200' '[.items[] | select(.registered_at != null and .age_days == null)] | length' '0'
# every filter reaches SQL: these are measured counts, each strictly inside the 294
assert '/dreps?has_script=true' '.total' '53'
assert '/dreps?anchor_status=unreachable' '.total' '51'
assert '/dreps?language=en-us' '.total' '50'
# voted_on / not_voted_on must partition the list exactly
assert '/dreps?voted_on=191398f38ef05515ddca265020d607fbb85c5651813f2429b38160fd491d9f8f%230' '[.total, .items[0].given_name]' '[1,"Bitcows"]'
assert '/dreps?not_voted_on=191398f38ef05515ddca265020d607fbb85c5651813f2429b38160fd491d9f8f%230' '.total' '293'
# q is bounded, and a LIKE metacharacter is matched literally rather than as a wildcard
assert_err '/dreps?q=a' '.code' '"query_too_short"'
assert '/dreps?q=100%25' '.total' '0'

# CSV: same filters, its own ceiling, injection-guarded, and no scientific notation.
#
# Fetched ONCE into a variable, deliberately. `curl -fsS ... | head -1` exits 23 (SIGPIPE) when
# head closes the pipe, and under `set -o pipefail` that failure becomes the pipeline's status —
# so the check would report FAIL while grep had in fact matched.
csv=$(curl -fsS -H 'Accept: text/csv' "$API/dreps?limit=10000")
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 => $2 (want $3)"; fail=1; fi; }

check "/dreps CSV header" \
  "$(printf '%s' "$csv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'id,hex,has_script'
check "/dreps CSV is 294 rows plus a header" "$(printf '%s\n' "$csv" | grep -c .)" 295
# Haskell's `show` renders 0.099 as 9.900990099009901e-2, which plenty of CSV tooling cannot read.
check "/dreps CSV rates are in fixed notation" \
  "$(printf '%s' "$csv" | tail -n +2 | grep -c 'e-0' || true)" 0
# The CSV and the JSON must say the same word for the same boolean.
check "/dreps CSV booleans match the JSON spelling" \
  "$(printf '%s' "$csv" | tail -n +2 | cut -d, -f3 | tr -d '\r' | sort -u | tr '\n' ' ')" 'false true '
# Every id cell is a bech32 string, so none of them can be read as a formula; assert it anyway,
# because the guard is the thing under test and a passing guard must be visible.
check "/dreps CSV has no unguarded formula lead" \
  "$(printf '%s' "$csv" | tail -n +2 | grep -cE '^[=+@]' || true)" 0

if [ "$fail" = 0 ]; then echo "smoke OK"; else echo "smoke FAILED" >&2; fi
exit $fail
