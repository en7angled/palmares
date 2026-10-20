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

if [ "$fail" = 0 ]; then echo "smoke OK"; else echo "smoke FAILED" >&2; fi
exit $fail
