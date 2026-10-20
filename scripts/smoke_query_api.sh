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

echo "== DRep profile (T-API-9)"
D=drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg
assert "/drep/$D" '.drep.id' "\"$D\""
assert "/drep/$D" '.drep.hex' '"81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8"'
assert "/drep/$D" '[.drep.has_script, (.drep.status == "active")]' '[false,true]'
# Two paths, one handler, one response type. Byte-identical or the alias has diverged.
if diff <(j "/drep/$D" '.') <(j "/pages/drep/$D" '.') >/dev/null; then
  echo "  ok   /pages/drep/{id} is byte-identical to /drep/{id}"
else
  echo "  FAIL the page alias diverges from /drep/{id}"; fail=1
fi
assert "/drep/$D" '.metrics.formula_ids | sort' \
  '["age_days_v1","delegator_retention_rate_v1","participation_rate_v1","rationale_rate_v1","vote_latency_median_hours_v1","votes_by_type_v1"]'
# THE test of the per-type breakdown: the sigma row. Each column must sum to the headline figure,
# or the breakdown and the headline were measured differently.
assert "/drep/$D" '[([.metrics.votes_by_type[] | .[1].eligible_actions] | add) == .metrics.eligible_actions, ([.metrics.votes_by_type[] | .[1].votes_cast] | add) == .metrics.votes_cast, ([.metrics.votes_by_type[] | .[1] | (.yes+.no+.abstain)] | add) == .metrics.votes_cast]' \
  '[true,true,true]'
# the five rationale grades also sum to votes_cast, by construction
assert "/drep/$D" '(.metrics | [.rationale_verified,.rationale_inline,.rationale_unverified,.rationale_pending,.rationale_absent] | add) == .metrics.votes_cast' 'true'
# final votes sum to votes_cast: one verdict per action, the LAST one
assert "/drep/$D" '(.metrics.final_votes | .yes + .no + .abstain) == .metrics.votes_cast' 'true'
# all seven action types always appear, even at zero
assert "/drep/$D" '[.metrics.votes_by_type[] | .[0]] | sort' \
  '["hard_fork_initiation","info_action","new_committee","new_constitution","no_confidence","parameter_change","treasury_withdrawals"]'
# preprod: 6 of this DRep's final votes on TreasuryWithdrawals, 1 yes and 5 no
assert "/drep/$D" '[.metrics.votes_by_type[] | select(.[0]=="treasury_withdrawals") | .[1] | [.yes,.no,.abstain]][0]' '[1,5,0]'
# The power series has REAL gaps: epochs 203-208 are absent from drep_distr for this DRep and are
# not zero-filled, because inventing a row turns an absence into a measurement.
assert "/drep/$D" '.power_by_epoch | length' '141'
assert "/drep/$D" '.power_by_epoch | [.[0].epoch, .[-1].epoch]' '[174,320]'
assert "/drep/$D" '.power_by_epoch | map(.epoch) | . == (. | sort)' 'true'
assert "/drep/$D" '[.power_by_epoch[] | has("rank")] | unique' '[false]'
# The retention block comes from RUNNING delegator_retention_rate_v1, not from a second
# derivation: a cumulative "ever delegated" reading gave 26 and 0.42 where the formula gives 11
# and 1.0, and the counters below are the formula's.
assert "/drep/$D" '.delegator_stats | [.delegators_retained + .delegators_left == .delegator_count_prev, .delegators_retained + .delegators_joined == .delegator_count, .window_epochs]' '[true,true,10]'
assert "/drep/$D" '.delegator_stats | (.delegator_retention_rate * 1000000 | round) == ((.delegators_retained / .delegator_count_prev) * 1000000 | round)' 'true'
assert "/drep/$D" '.top_delegators | length <= 10' 'true'
# CIP-119 metadata, served only because this anchor's hash verified
assert "/drep/$D" '[.anchor_content.given_name, .drep.anchor_status]' '["Bitcows","valid"]'
# certificate history: a registration in epoch 173 and a metadata update in 208
assert "/drep/$D/updates" '[.items[] | [.kind, .deposit]] | sort' '[["registered",500000000],["updated",null]]'
assert "/drep/$D/updates" '[.items[0].kind, .items[0].at.epoch]' '["updated",208]'
assert "/drep/$D/updates?kind=registered" '[.total, .items[0].at.epoch]' '[1,173]'
assert "/drep/$D/power?from_epoch=320&to_epoch=320" '.items | map([.epoch, .lovelace])' '[[320,3923709956713]]'
assert "/drep/$D/delegators?limit=50" '[.total, ([.items[] | select(.is_current)] | length)]' '[12,12]'
# is_current=false widens to the history, so it can only be a superset
assert "/drep/$D/delegators?limit=50&is_current=false" '.total >= 12' 'true'
# a DRep with nothing settled serves nulls, not zeros (f1-metric 3.8). The list form is the gate
# because it does not depend on which DRep happens to be newest.
assert '/dreps?limit=200' '[.items[] | select(.eligible_actions == 0) | .participation_rate] | unique | . == [] or . == [null]' 'true'
# error shapes: EVERY failure carries {code, message}, including the ones servant's routing layer
# produces before a handler runs
assert_err '/drep/drep1yt0dahk7mm0dahk7mm0dahk7mm0dahk7mm0dahk7mm0dahs0s7gtm' '.code' '"drep_not_found"'
assert_err "/drep/drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xq" '.code' '"invalid_drep_id"'
assert_err '/drep/pool1abc' '.code' '"invalid_drep_id"'
assert_err '/drep/drep_always_abstain' '.code' '"drep_not_found"'
assert_err '/dreps?status=nonsense' '.code' '"invalid_parameter"'
for p in '/drep/drep1yt0dahk7mm0dahk7mm0dahk7mm0dahk7mm0dahk7mm0dahs0s7gtm:404' '/drep/pool1abc:400' '/dreps?status=nonsense:400'; do
  path="${p%:*}"; want="${p##*:}"
  got=$(code "$path")
  if [ "$got" = "$want" ]; then echo "  ok   $path is $want"; else echo "  FAIL $path is $got (want $want)"; fail=1; fi
done

echo "== governance actions (T-API-11)"
assert '/gov-actions?limit=1' '.total' '131'
assert '/gov-actions?limit=1' '.items[0].id | test("^[0-9a-f]{64}#[0-9]+$")' 'true'
assert '/gov-actions?limit=1' '.items[0].bech32 | startswith("gov_action1")' 'true'
# `state` is SINGLE-VALUED: gov_action_state_v1 reads the four lifecycle columns in a fixed order,
# so these are NOT the per-column counts. 0 ratified because every ratified action was enacted the
# next epoch, and 102 of the 108 rows carrying dropped_epoch also carry expired_epoch.
#
# The plan's draft had `proposed` at 12, which made the five sum to 132 against 131 rows. Read off
# the database: 11. That was the plan's own OPEN, and the database closed it.
assert '/gov-actions?state=enacted&limit=1'  '.total' '11'
assert '/gov-actions?state=ratified&limit=1' '.total' '0'
assert '/gov-actions?state=expired&limit=1'  '.total' '103'
assert '/gov-actions?state=dropped&limit=1'  '.total' '6'
assert '/gov-actions?state=proposed&limit=1' '.total' '11'
# THE assertion: the five states partition all 131 rows. This is what catches a mis-ordered CASE.
assert '/gov-actions?limit=200' '[([.items[].lifecycle.state] | length), ([.items[].lifecycle.state] | group_by(.) | map(length) | add)]' '[131,131]'
assert '/gov-actions?limit=200' '[.items[].type] | unique | sort' \
  '["hard_fork_initiation","info_action","new_committee","new_constitution","no_confidence","parameter_change","treasury_withdrawals"]'
# The observed window is 7 epochs on all 131, while gov_action_lifetime reads 6: the ledger sets
# expiration = proposed_epoch + lifetime + 1. Both numbers are published, and this is why.
assert '/gov-actions?limit=200' '[.items[] | select(.expires_epoch != null) | .expires_epoch - .proposed_at.epoch] | unique' '[7]'
# treasury_amount is set for exactly the TreasuryWithdrawals actions and null for the rest
assert '/gov-actions?type=treasury_withdrawals&limit=200' '[.total, ([.items[] | select(.treasury_amount == null)] | length)]' '[82,0]'
assert '/gov-actions?limit=200' '[.items[] | select(.type != "treasury_withdrawals" and .treasury_amount != null)] | length' '0'
assert '/gov-actions?order_by=deposit&sort_order=desc&limit=5' '[.items[].deposit] | . == (. | sort | reverse)' 'true'
# an enacted action carries enacted_epoch = ratified_epoch + 1 and no expiry or drop
assert '/gov-actions?state=enacted&limit=200' '[.items[] | .lifecycle | [(.enacted_epoch - .ratified_epoch), .expired_epoch, .dropped_epoch]] | unique' '[[1,null,null]]'
assert '/gov-actions?state=enacted&limit=1' '.items[0].lifecycle.formula_id' '"gov_action_state_v1"'
# stable paging over a heavily tied key: 103 rows share a state and 82 share a type
assert '/gov-actions?order_by=type&limit=200' '[.items[].id] | (length) == (unique | length)' 'true'
# the filters reach SQL
assert '/gov-actions?type=info_action' '.total' '17'
assert '/gov-actions?type=info_action&type=no_confidence' '.total' '19'
assert '/gov-actions?expires_after_epoch=320' '.total' '11'
assert_err '/gov-actions?q=a' '.code' '"query_too_short"'
assert_err '/gov-actions?state=nonsense' '.code' '"invalid_parameter"'
gacsv=$(curl -fsS -H 'Accept: text/csv' "$API/gov-actions?limit=10000")
check "/gov-actions CSV header" \
  "$(printf '%s' "$gacsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'id,bech32,type'
check "/gov-actions CSV is 131 rows plus a header" "$(printf '%s\n' "$gacsv" | grep -c .)" 132

echo "== governance action page (T-API-12)"
# The BECH32 form in the path, not the canonical one: `#` is a URL fragment delimiter, so
# <tx_hash>#<index> only works percent-encoded. Both are accepted; one of them is linkable.
GW=$(j '/gov-actions?type=treasury_withdrawals&limit=1' '.items[0].bech32' | tr -d '"')
GWID=$(j '/gov-actions?type=treasury_withdrawals&limit=1' '.items[0].id' | tr -d '"')
GE=$(j '/gov-actions?state=enacted&limit=1' '.items[0].bech32' | tr -d '"')
GP=$(j '/gov-actions?type=parameter_change&limit=1' '.items[0].bech32' | tr -d '"')
# One handler, two paths.
if diff <(j "/gov-action/$GW" '.') <(j "/pages/gov-action/$GW" '.') >/dev/null; then
  echo "  ok   /pages/gov-action/{id} is byte-identical to /gov-action/{id}"
else
  echo "  FAIL the gov-action page alias diverges"; fail=1
fi
# the percent-encoded canonical form resolves to the same action
assert "/gov-action/$(printf '%s' "$GWID" | sed 's/#/%23/')" '.action.bech32' "\"$GW\""
assert "/gov-action/$GW" '.action.id' "\"$GWID\""
assert "/gov-action/$GW" '[.tallies[].basis] | unique | . == [] or . == ["cast_votes_only"]' 'true'
assert "/gov-action/$GW" '[.tallies[].formula_id] | unique | . == [] or . == ["tally_cast_votes_v1"]' 'true'
# treasury_withdrawals: the DRep threshold column is named even while the action is still open
assert "/gov-action/$GW" '[.tallies[] | select(.role=="drep") | .threshold_param] | .[0] // null' '"dvt_treasury_withdrawal"'
# SPOs do not vote on treasury withdrawals, so there is no SPO threshold to name
assert "/gov-action/$GW" '[.tallies[] | select(.role=="spo") | .threshold_param] | unique | . == [] or . == [null]' 'true'
# 83 withdrawals recorded on preprod and NONE enacted, so enacted_at is null throughout
assert "/gov-action/$GW" '.withdrawals | length >= 1' 'true'
assert "/gov-action/$GW" '.withdrawals[0] | [(.beneficiary | startswith("stake")), (.amount > 0), .enacted_at]' '[true,true,null]'
assert "/gov-action/$GW" '.proposer | [(.stake_address | startswith("stake")), (.actions_count >= 1)]' '[true,true]'
# A parameter_change publishes the parameters it touches, each with its CIP-1694 group, and its
# DRep threshold is the max OVER those groups -- which palmares.vote_tally deliberately leaves
# null because it is a property of the proposal, not of its type.
assert "/gov-action/$GP" '.param_changes | length >= 1' 'true'
assert "/gov-action/$GP" '[.param_changes[].group] | unique | map(startswith("dvt_p_p_")) | unique' '[true]'
# An enacted parameter_change touching two groups: a real number, resolved through greatest(...)
# over the columns Query.Thresholds named.
assert "/gov-action/$GE" '[.tallies[] | select(.role=="drep") | [(.threshold != null), (.threshold > 0), (.threshold <= 1)]] | .[0] // [true,true,true]' '[true,true,true]'
assert "/gov-action/$GE" '[.tallies[] | select(.role=="drep") | (.threshold_param | startswith("dvt_p_p_") or startswith("greatest(dvt_p_p_"))] | .[0] // true' 'true'
# The committee has counts and no power: it ratifies by member quorum and holds no stake.
assert "/gov-action/$GE" '[.tallies[] | select(.role=="constitutional_committee") | [.yes_power, .no_power, .threshold]] | .[0] // [0,0,null]' '[0,0,null]'
# ratio is null ONLY when no power sits behind either side. A unanimous action must read 1, not
# null -- a FILTERed sum over no rows is NULL, so `yes + NULL` published "no votes cast" for 33 of
# the 49 tallies that carry power until this was fixed.
assert "/gov-action/$GE" '[.tallies[] | select(.yes_power + .no_power > 0) | .ratio] | map(. != null) | unique | . == [] or . == [true]' 'true'
assert "/gov-action/$GE" '[.tallies[] | select(.yes_power + .no_power == 0) | .ratio] | unique | . == [] or . == [null]' 'true'
assert_err '/gov-action/0000000000000000000000000000000000000000000000000000000000000000%230' '.code' '"gov_action_not_found"'
assert_err '/gov-action/nope' '.code' '"invalid_gov_action_id"'
for p in "/gov-action/0000000000000000000000000000000000000000000000000000000000000000%230:404" "/gov-action/nope:400"; do
  path="${p%:*}"; want="${p##*:}"; got=$(code "$path")
  if [ "$got" = "$want" ]; then echo "  ok   $path is $want"; else echo "  FAIL $path is $got (want $want)"; fail=1; fi
done

echo "== votes (T-API-13)"
# preprod role totals. The committee figure is the epoch-187 stress test, not participation:
# 3.24 M rows from 648,766 hot keys resolving to 43 cold credentials.
assert '/votes?voter_role=spo&limit=1' '.total' '90'
assert '/votes?voter_role=drep&limit=1' '.total >= 819' 'true'
assert '/votes?voter_role=constitutional_committee&limit=1' '.total >= 3243802' 'true'
assert '/votes?voter_role=drep&limit=200' '[.items[].voter_role] | unique' '["drep"]'
# has_rationale is spelled anchor_status=valid. Measured: 1 DRep vote and 0 SPO votes carry a
# verified anchor, which is a statement about IPFS reachability and not about 36 authors.
assert '/votes?voter_role=spo&anchor_status=valid&limit=1' '.total' '0'
assert '/votes?voter_role=drep&anchor_status=valid&limit=1' '.total >= 1' 'true'
# the fixture DRep: 16 votes, one verdict each, no re-votes, two anchors attached
assert "/votes?voter_id=$D&limit=100" '[.total, ([.items[] | select(.revote_count > 1)] | length)]' '[16,0]'
assert "/votes?voter_id=$D&limit=100" '[.items[].verdict] | group_by(.) | map([.[0], length]) | sort' \
  '[["abstain",1],["no",8],["yes",7]]'
assert "/votes?voter_id=$D&limit=100" '[.items[] | select(.anchor != null)] | length' '2'
# the latency extremes are the fixture's own sample bounds
assert "/votes?voter_id=$D&order_by=latency&sort_order=asc&limit=1" '.items[0].latency_hours * 100 | round' '129'
assert "/votes?voter_id=$D&order_by=latency&sort_order=desc&limit=1" '.items[0].latency_hours * 100 | round' '63008'
# every row of a re-voted pair is returned, and exactly one of them is final
assert "/votes?voter_id=$D&limit=100" '[.items[] | select(.is_final)] | length' '16'
# D-24: a committee vote is addressed by the COLD credential and the id ROUND-TRIPS, for both
# credential kinds. 32 of the 43 cold keys that voted are key credentials and 11 are scripts, so
# publishing one header byte for all of them mis-identified eleven of them until this was fixed.
CCID=$(j '/votes?voter_role=constitutional_committee&limit=1' '.items[0].voter_id' | tr -d '"')
assert "/votes?voter_id=$CCID&limit=1" '.items[0].voter_id' "\"$CCID\""
assert "/votes?voter_id=$CCID&limit=1" '.items[0] | [.voter_role, (.voter_hot_hash != null)]' '["constitutional_committee",true]'
assert "/votes?voter_id=$CCID&limit=1" '.total > 0' 'true'
assert "/votes?voter_role=constitutional_committee&limit=1" '.items[0].voter_id | startswith("cc_cold1")' 'true'
# a stake pool is published in CIP-5 pool1… form: no CIP-129 exists for a pool and no tool shows one
assert '/votes?voter_role=spo&limit=1' '.items[0].voter_id | startswith("pool1")' 'true'
# power and its epoch are null together: a committee member holds no stake
assert '/votes?voter_role=drep&limit=200' '[.items[] | ((.voting_power == null) == (.voting_power_epoch == null))] | unique' '[true]'
assert '/votes?voter_role=constitutional_committee&limit=1' '.items[0] | [.voting_power, .voting_power_epoch]' '[null,null]'
assert_err '/votes?from_epoch=321&to_epoch=320' '.code' '"invalid_epoch_range"'
# a mistyped voter id is a 400, not an empty page: a client should be told, not shown "never voted"
assert_err '/votes?voter_id=nonsense' '.code' '"invalid_drep_id"'
vcsv=$(curl -fsS -H 'Accept: text/csv' "$API/votes?voter_role=spo&limit=10000")
check "/votes CSV header" \
  "$(printf '%s' "$vcsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'gov_action_id,gov_action_bech32,gov_action_type'
check "/votes CSV is 90 SPO rows plus a header" "$(printf '%s\n' "$vcsv" | grep -c .)" 91

if [ "$fail" = 0 ]; then echo "smoke OK"; else echo "smoke FAILED" >&2; fi
exit $fail
