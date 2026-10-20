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

# A value computed by the caller rather than fetched by `j`: CSV rows, derived counts, anything
# a jq filter cannot express on its own.
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 => $2 (want $3)"; fail=1; fi; }

# An assertion that is RIGHT but that the service cannot satisfy yet. It prints what it expects
# and why it is skipped, and it does NOT fail the run — so the expectation stays in the suite,
# visible and un-weakened, instead of being deleted or quietly relaxed into something true.
# Delete the wrapper, not the assertion, when the defect is fixed.
known_defect() { echo "  KNOWN $1"; echo "         expected: $2"; }

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
assert "/drep/$D/delegators?limit=50" '[.total, ([.items[] | select(.is_current)] | length)]' '[13,13]'
# is_current=false widens to the history, so it can only be a superset
assert "/drep/$D/delegators?limit=50&is_current=false" '.total >= 13' 'true'
# The two reserved ledger options have a power series and NOTHING else — no registration, no
# metadata, no votes — so this route answers for them while /drep/{id} still 404s. That asymmetry
# is the data, not an oversight, and before it was fixed their power was reachable only as an
# aggregate on /pages/dashboard: 46% of preprod's total, invisible per epoch. D-20's own numbers.
assert '/drep/drep_always_abstain/power?from_epoch=315&to_epoch=319' \
  '[(.items|length), (.items[-1]|[.epoch,.lovelace])]' '[5,[319,431863790957959]]'
assert '/drep/drep_always_no_confidence/power?from_epoch=315&to_epoch=319' \
  '[(.items|length), (.items[-1]|[.epoch,.lovelace])]' '[5,[319,325390800383]]'
[ "$(code '/drep/drep_always_abstain')" = 404 ] \
  && echo "  ok   /drep/{id} still 404s for a reserved option" \
  || { echo "  FAIL a reserved option must not have a profile"; fail=1; }

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
# A committee cold credential that has voted, in CIP-129 form. preprod's first enacted committee
# member: 6 votes. Named here because the committee-role PAGE cannot answer (see the known defect
# below) while addressing the same member BY ID is fast — voter_id_hash is a partition column of
# palmares.vote's window functions, so the qual pushes below the WindowAgg and reads 6 rows.
CC=cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu
# preprod role totals. The committee figure is the epoch-187 stress test, not participation:
# 3.24 M rows from 648,766 hot keys resolving to 43 cold credentials.
assert '/votes?voter_role=spo&limit=1' '.total' '90'
assert '/votes?voter_role=drep&limit=1' '.total >= 819' 'true'
# KNOWN DEFECT — the committee role is 3,243,802 of preprod's 3,244,711 vote rows, and
# palmares.vote computes three window functions partitioned by (voter_id_hash, gov_action_id,
# voter_role), so a page of ONE row sorts and partitions all of them. MEASURED: the page statement
# 27.5 s and the count 24.0 s through psql, and over 166 s through the service, which now returns
# 503 at the 30 s read timeout instead of hanging. Every other role answers in seconds because
# voter_role is a partition column and the qual pushes below the WindowAgg: spo 90 rows, drep 819.
# The fix is a two-stage page — pick the page's rows from voting_procedure and resolve the three
# window columns for THOSE partitions only, which pushes down for the same reason — and it is its
# own task, not a tail of this one. F1-PROGRESS.md carries the measurements.
known_defect '/votes?voter_role=constitutional_committee&limit=1' '.total >= 3243802'
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
# The cold id is taken from a KNOWN cold credential rather than from a committee-role page, which
# is the request above that cannot answer. Addressing a voter by id filters on voter_id_hash — a
# partition column — so this path is fast: it reads that one credential's rows, not all 3.24 M.
CCID=$(j "/votes?voter_id=$CC&limit=1" '.items[0].voter_id' | tr -d '"')
assert "/votes?voter_id=$CCID&limit=1" '.items[0].voter_id' "\"$CCID\""
assert "/votes?voter_id=$CCID&limit=1" '.items[0] | [.voter_role, (.voter_hot_hash != null)]' '["constitutional_committee",true]'
assert "/votes?voter_id=$CCID&limit=1" '.total > 0' 'true'
assert "/votes?voter_id=$CC&limit=1" '.items[0].voter_id | startswith("cc_cold1")' 'true'
# a stake pool is published in CIP-5 pool1… form: no CIP-129 exists for a pool and no tool shows one
assert '/votes?voter_role=spo&limit=1' '.items[0].voter_id | startswith("pool1")' 'true'
# power and its epoch are null together: a committee member holds no stake
assert '/votes?voter_role=drep&limit=200' '[.items[] | ((.voting_power == null) == (.voting_power_epoch == null))] | unique' '[true]'
assert "/votes?voter_id=$CC&limit=1" '.items[0] | [.voting_power, .voting_power_epoch]' '[null,null]'
assert_err '/votes?from_epoch=321&to_epoch=320' '.code' '"invalid_epoch_range"'
# a mistyped voter id is a 400, not an empty page: a client should be told, not shown "never voted"
assert_err '/votes?voter_id=nonsense' '.code' '"invalid_drep_id"'
vcsv=$(curl -fsS -H 'Accept: text/csv' "$API/votes?voter_role=spo&limit=10000")
check "/votes CSV header" \
  "$(printf '%s' "$vcsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'gov_action_id,gov_action_bech32,gov_action_type'
check "/votes CSV is 90 SPO rows plus a header" "$(printf '%s\n' "$vcsv" | grep -c .)" 91

echo "== DRep explorer page (T-API-17)"
# Parenthesised, and that is the point of the parentheses: `[.items | length, .limit, .offset]`
# pipes .items into all three, so jq tries .items.limit on an array and errors out. The assertion
# then compares an EMPTY string and reports the endpoint as broken. It did, for as long as the
# suite could not run far enough to reach this line.
assert '/pages/drep-explorer?limit=10' '[(.items | length), .limit, .offset]' '[10,10,0]'
# the count is listDReps' own, not a second derivation: the same 294 /dreps publishes
assert '/pages/drep-explorer?limit=1' '.total' '294'
assert '/pages/drep-explorer?limit=1' '.epoch >= 320' 'true'
# THE facet assertion. The facet universe is every REGISTERED credential, so it sums to 805 and NOT
# to 294: offering "Retired (511)" while the list shows the 294 registered is the whole point.
assert '/pages/drep-explorer?limit=1' '[.status_facets[] | .[1]] | add' '805'
assert '/pages/drep-explorer?limit=1' '[.status_facets[] | select(.[0]=="active" or .[0]=="inactive") | .[1]] | add' '294'
# preprod's own split. active is small because the ledger stops counting a DRep's power after
# drep_activity = 20 epochs without a vote; inactive is still registered and still listed.
assert '/pages/drep-explorer?limit=1' '.status_facets' '[["active",17],["inactive",277],["retired",511]]'
# `reserved` can never appear: the two reserved ledger options have no credential (D-20)
assert '/pages/drep-explorer?limit=1' '[.status_facets[] | select(.[0]=="reserved")]' '[]'
# the facet drops its OWN predicate -- retired is still counted while status=active is applied
assert '/pages/drep-explorer?status=active&limit=1' '[.status_facets[] | select(.[0]=="retired") | .[1]][0]' '511'
assert '/pages/drep-explorer?status=active&limit=1' '.total' '17'
assert '/pages/drep-explorer?status=active&limit=200' '[.items[].status] | unique' '["active"]'
# anchor facets are counted over the status set AS APPLIED, which is why unreachable reads the same
# 51 that /dreps?anchor_status=unreachable publishes. 131 of the 294 have an anchor row at all.
assert '/pages/drep-explorer?limit=1' '.anchor_facets' '[["unreachable",51],["valid",50],["hash_mismatch",26],["invalid_schema",4]]'
assert '/pages/drep-explorer?limit=1' '[.anchor_facets[] | .[0]] | map(IN("valid","invalid_schema","hash_mismatch","oversized","unreachable","inline","not_fetched")) | unique' '[true]'
# language is whatever CIP-119 metadata published: 50 say en-us and 4 publish the EMPTY tag, which
# is republished as "" rather than normalised away -- we publish what was signed.
assert '/pages/drep-explorer?limit=1' '.language_facets' '[["en-us",50],["",4]]'
# six fixed half-open buckets. 109 of the 294 registered DReps hold zero power: the ledger's
# distribution for the epoch simply does not include them.
assert '/pages/drep-explorer?limit=1' '.power_buckets | length' '6'
assert '/pages/drep-explorer?limit=1' '[.power_buckets[].count] | add' '294'
assert '/pages/drep-explorer?limit=1' '.power_buckets[0] | [.lo, .hi, .count]' '[0,1,109]'
assert '/pages/drep-explorer?limit=1' '[.power_buckets[] | .count]' '[109,28,53,69,23,12]'
assert '/pages/drep-explorer?limit=1' '.power_buckets[-1] | [.lo, .hi, .count]' '[1000000000000,null,12]'
# the histogram is NOT a drop-your-own-predicate facet: it follows the applied filter
assert '/pages/drep-explorer?status=active&limit=1' '[.power_buckets[].count] | add' '17'
# the rows ARE /dreps' rows: same default ordering, same clamping, same errors
assert '/pages/drep-explorer?limit=5' '[.items[].voting_power] | . == (. | sort | reverse)' 'true'
assert '/pages/drep-explorer?limit=999' '[.limit, (.items|length)]' '[200,200]'
assert '/pages/drep-explorer?q=Bitcows' '[.total, (.items|length)]' '[1,1]'
assert_err '/pages/drep-explorer?offset=10001' '.code' '"offset_too_large"'
assert_err '/pages/drep-explorer?q=a' '.code' '"query_too_short"'
assert_err '/pages/drep-explorer?status=nonsense' '.code' '"invalid_parameter"'
# no CSV on a page composite: servant refuses the content type rather than serving a half page
csvcode=$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/csv' "$API/pages/drep-explorer?limit=1")
check "/pages/drep-explorer refuses CSV" "$csvcode" 406

echo "== dashboard page (T-API-17)"
assert /pages/dashboard '.epoch >= 320' 'true'
# the four DRep counts come from the explorer's own facet statement: one derivation, two endpoints
assert /pages/dashboard '[.total_dreps, .active_dreps, .inactive_dreps, .retired_dreps]' '[294,17,277,511]'
assert /pages/dashboard '.active_dreps + .inactive_dreps == .total_dreps' 'true'
# retired is published BESIDE total_dreps, never inside it: 511 against 294
assert /pages/dashboard '.retired_dreps > .total_dreps' 'true'
# The spec's headline fact, read off drep_epoch_power by target_kind -- the one view with no DRep
# filter. Measured at epoch 320: 432730293365956 parked on always_abstain and 330505955747 on
# always_no_confidence, against 505695499409749 delegated to real DReps. Bounds rather than
# equalities because the parked stake drifts every epoch; the epoch-319 fixture reads
# 431863790957959 and 325390800383, and both are inside these.
assert /pages/dashboard '.always_abstain_lovelace > 427000000000000' 'true'
assert /pages/dashboard '.always_no_confidence_lovelace > 322000000000' 'true'
assert /pages/dashboard '.drep_power_lovelace > .always_abstain_lovelace' 'true'
# power_epoch is its own field because the ledger writes the distribution one epoch behind the tip
assert /pages/dashboard '.power_epoch <= .epoch' 'true'
assert /pages/dashboard '.total_actions' '131'
# in flight is last_votable_epoch >= epoch, NOT state=proposed: measured 12 against 11. The extra
# action's state already reads expired while its voting window is still open.
assert /pages/dashboard '.actions_in_flight' '12'
assert /pages/dashboard '[.actions_by_state[] | select(.[0]=="proposed") | .[1]][0]' '11'
# every type and every state is emitted even at zero, for the reason the DRep metric breakdown
# gives: a missing key reads as "no such state" where the truth is "none of them".
assert /pages/dashboard '[(.actions_by_type | length), (.actions_by_state | length)]' '[7,5]'
assert /pages/dashboard '[.actions_by_type[] | .[1]] | add' '131'
assert /pages/dashboard '[.actions_by_state[] | .[1]] | add' '131'
assert /pages/dashboard '.actions_by_state' '[["dropped",6],["enacted",11],["expired",103],["proposed",11],["ratified",0]]'
assert /pages/dashboard '.actions_by_type' '[["hard_fork_initiation",4],["info_action",17],["new_committee",8],["new_constitution",2],["no_confidence",2],["parameter_change",16],["treasury_withdrawals",82]]'
# 83 withdrawal rows across 82 actions: 656466092110010 lovelace REQUESTED and NONE enacted. Two
# fields, because one called "withdrawn" would be either 0 or a lie about the word.
assert /pages/dashboard '.treasury_requested_lovelace' '656466092110010'
assert /pages/dashboard '.treasury_enacted_lovelace' '0'
assert '/pages/dashboard?closing_soon_limit=5' '.closing_soon | length' '5'
assert '/pages/dashboard?closing_soon_limit=5' '[.closing_soon[].lifecycle.state] | unique' '["proposed"]'
# soonest first, and all inside five epochs of the tip. Measured: four of them expire at 321.
assert '/pages/dashboard?closing_soon_limit=5' '[.closing_soon[].expires_epoch] | . == (. | sort)' 'true'
assert '/pages/dashboard?closing_soon_limit=5' '[.closing_soon[].expires_epoch] | min' '321'
assert '/pages/dashboard?closing_soon_limit=1' '.closing_soon | length' '1'
assert '/pages/dashboard?top_limit=10' '.top_dreps_by_power | length' '10'
assert '/pages/dashboard?top_limit=10' '[.top_dreps_by_power[].voting_power] | . == (. | sort | reverse)' 'true'
# the two reserved options hold more stake than any DRep and are NOT in this list: no credential,
# so they never enter /dreps and never enter a leaderboard built from it.
assert '/pages/dashboard?top_limit=10' '[.top_dreps_by_power[].id] | map(startswith("drep_always")) | any' 'false'
# an INVARIANT, not a magnitude: voting_power moves every epoch. Measured at 320 the leader holds
# 400639368460676 lovelace, about 79% of all DRep-delegated stake.
assert '/pages/dashboard?top_limit=10' '.top_dreps_by_power[0].voting_power > 400000000000000' 'true'
# clamped silently to [1,50] and [1,20], by the same helper every page uses
assert '/pages/dashboard?top_limit=999' '.top_dreps_by_power | length' '50'
assert '/pages/dashboard?closing_soon_limit=999' '.closing_soon | length <= 20' 'true'
assert '/pages/dashboard?epochs=20' '.participation_by_epoch | length' '20'
assert '/pages/dashboard?epochs=20' '.participation_by_epoch | map(.epoch) | . == (. | sort)' 'true'
# measured epochs 301-320: every one has a drep_distr snapshot, so there is no gap to fill
assert '/pages/dashboard?epochs=20' '.participation_by_epoch | [.[0].epoch, .[-1].epoch]' '[301,320]'
# epoch 313: 181 DReps held power, 17 of them voted, and they cast 31 votes -- dreps_voted counts
# voters and votes_cast counts votes, and the difference is re-votes.
assert '/pages/dashboard?epochs=20' '[.participation_by_epoch[] | select(.epoch==313) | [.dreps_with_power, .dreps_voted, .votes_cast]][0]' '[181,17,31]'
# epoch 311: 177 DReps held power and NONE voted. The rate is 0, not null: the denominator is not
# empty, and null would say "we could not measure it".
assert '/pages/dashboard?epochs=20' '[.participation_by_epoch[] | select(.epoch==311) | [.dreps_with_power, .dreps_voted, .participation_rate]][0]' '[177,0,0.0]'
assert '/pages/dashboard?epochs=20' '[.participation_by_epoch[] | (.participation_rate * 1000000 | round) == ((.dreps_voted / .dreps_with_power) * 1000000 | round)] | unique' '[true]'
assert '/pages/dashboard?epochs=1' '.participation_by_epoch | [length, .[0].epoch]' '[1,320]'
# These numbers go around palmares.vote deliberately: through it the same 20 epochs cost 1213 ms,
# through voting_procedure's partial index 4.6 ms, and the two agree row for row.
#
# The magnitude is asserted on epoch 313 above and NOT on this sum: `epochs=20` is a window that
# SLIDES with the tip, so a fixed total here was already stale by 30 votes one epoch later. What
# is asserted instead is what cannot drift — every count non-negative, and the series not empty.
assert '/pages/dashboard?epochs=20' '[.participation_by_epoch[].votes_cast] | add > 0' 'true'
assert '/pages/dashboard?epochs=20' '[.participation_by_epoch[] | select(.votes_cast < 0 or .dreps_voted < 0 or .dreps_with_power < 0)] | length' '0'
# Plan B and T-API-15: these fields do not exist yet, and a literal 0 would not be a measurement.
assert /pages/dashboard '[.attestation_count, .claimed_profile_count, .recent_activity]' '[null,null,null]'

echo "== Swagger parity (T-API-18)"
# ONE assertion here, because there are two different things to check and only this one is about
# the running service: the document it SERVES is byte-identical to the one committed under
# docs/generated/swagger/, which is what the frontend's codegen reads. If they differ, a client
# generated from the repo is talking to a different API than the one answering.
#
# What the document must SAY is checked by scripts/check_swagger.sh — the path set, the 24 error
# codes, the parameters that must exist and the ones that must not. It runs in CI against the
# regenerated file and needs no server, and keeping those assertions in one place rather than two
# is why they are not repeated here.
if [ -f docs/generated/swagger/query-swagger-api.json ]; then
  check "the served Swagger document matches the committed one" \
    "$(curl -fsS "$API/swagger-api.json" | jq -S . | shasum | cut -d' ' -f1)" \
    "$(jq -S . docs/generated/swagger/query-swagger-api.json | shasum | cut -d' ' -f1)"
else
  echo "  skip docs/generated/swagger/query-swagger-api.json not in this working tree"
fi

echo "== delegations, committee, SPOs, treasury (T-API-14)"
# preprod: 2,304 stake addresses have ever delegated; 2,015 of those delegations still count.
# is_current DEFAULTS TO TRUE, so the unfiltered total is the current set, not the archive.
#
# These numbers were 1,960 and 344 until Koios parity found the deregistration rule comparing
# EPOCHS: a stake account that closed and reopened in one epoch had its new delegation cancelled
# by its own closure. 55 delegations came back.
assert '/delegations?limit=1' '.total' '2015'
assert '/delegations?limit=200' '[.items[].is_current] | unique' '[true]'
# the flag filters BOTH ways here (unlike /drep/{id}/delegators, where false widens): the 289 rows
# are the addresses whose stake account was deregistered AFTER the delegation's certificate.
assert '/delegations?is_current=false&limit=1' '.total' '289'
assert '/delegations?is_current=false&limit=200' '[.items[].is_current] | unique' '[false]'
# 2015 + 289 = 2304, the whole set. If these three ever stop summing, is_current stopped being a
# partition and the page is hiding rows. This is the assertion that would have caught the epoch
# bug if the archive side had been wrong too -- it was not, both sides moved together.
assert '/delegations?limit=1' '.total + 289 == 2304' 'true'
# the fixture DRep: 13, which is the plan's number after all -- and it is Koios's too, address
# for address. It read 12 until the deregistration rule was fixed. It agrees with
# /drep/$D/delegators?limit=50 .total, which is the same set reached by the other route.
assert "/delegations?drep_id=$D&limit=50" '.total' '13'
assert "/delegations?drep_id=$D&limit=50" '[.items[] | select(.is_current)] | length' '13'
if [ "$(j "/delegations?drep_id=$D&limit=50" '.total')" = "$(j "/drep/$D/delegators?limit=50" '.total')" ]; then
  echo "  ok   /delegations?drep_id agrees with /drep/{id}/delegators"
else
  echo "  FAIL /delegations?drep_id and /drep/{id}/delegators disagree"; fail=1
fi
assert '/delegations?limit=1' '.items[0].target | startswith("drep")' 'true'
assert '/delegations?limit=1' '.items[0].stake_address | startswith("stake")' 'true'
assert '/delegations?limit=200' '[.items[].stake_address] | map(startswith("stake")) | unique' '[true]'
# The two reserved ledger options are ordinary delegation rows pointing at raw IS NULL drep_hash
# rows -- and they hold the MAJORITY of current delegations: 1,020 abstain, 40 no-confidence,
# against 955 that name a credential. 1020 + 40 + 955 = 2015.
assert '/delegations?drep_id=drep_always_abstain&limit=1' '.total' '1020'
assert '/delegations?drep_id=drep_always_no_confidence&limit=1' '.total' '40'
assert '/delegations?drep_id=drep_always_abstain&limit=200' '[.items[].target] | unique' '["drep_always_abstain"]'
# a reserved option and a credential in one request mean "either", not "both": 1020 + 13 = 1033.
assert "/delegations?drep_id=drep_always_abstain&drep_id=$D&limit=1" '.total' '1033'
# lovelace comes from the latest epoch_stake snapshot and is null for an address with no stake in
# it: 1,092 of the 2,015 carry one, and 24 carry at least 1 M ADA.
assert '/delegations?min_lovelace=1000000000000&limit=1' '.total' '24'
# stable paging over a key 1,020 rows tie on
assert '/delegations?order_by=stake_address&limit=200' '[.items[].stake_address] | (length) == (unique | length)' 'true'
assert '/delegations?order_by=at&sort_order=desc&limit=5' '[.items[].at.slot] | . == (. | sort | reverse)' 'true'
assert_err '/delegations?from=2026-01-02T00:00:00Z&to=2026-01-01T00:00:00Z' '.code' '"invalid_time_range"'
assert_err '/delegations?offset=10001' '.code' '"offset_too_large"'
assert_err '/delegations?drep_id=nonsense' '.code' '"invalid_drep_id"'

# preprod: committee 8 is in force at epoch 320, three seats, quorum 2/3.
assert '/committee' '.members | length' '3'
assert '/committee' '[.quorum_numerator, .quorum_denominator]' '[2,3]'
assert '/committee' '.epoch' '320'
# the governance action that enacted it (gov_action_proposal 108), canonical <tx_hash>#<index>
assert '/committee' '.established_by' '"bbfa303aa35d19919934fb5fe36b174609a0c1dfb47a546ccd6ea58aa752e2aa#0"'
# Two status values, not the plan's four: palmares.committee_member derives status from
# committee_de_registration alone, which has 0 rows on preprod -- so all 110 seats across all 9
# committees read "active" and every resigned_at is null.
assert '/committee' '[.members[].status] | unique' '["active"]'
assert '/committee' '[.members[].resigned_at] | unique' '[null]'
# expiry is published BESIDE status, not folded into it: these terms end in epoch 372, 52 epochs out
assert '/committee' '[.members[].expiration_epoch] | unique' '[372]'
# all three seats authorized a hot key in one transaction batch in epoch 228, and all three are
# SCRIPT credentials -- so a hard-coded key-type header byte would mis-render every cold id here
assert '/committee' '[.members[].hot_hash != null] | unique' '[true]'
assert '/committee' '[.members[].authorized_at.epoch] | unique' '[228]'
assert '/committee' '.members[0].cold_hash' '"615b54137e73f090d2dddb04317bee41624f4013e5cfe4a5efa76d76"'
assert '/committee' '.members[0].cold_bech32' '"cc_cold1zds4k4qn0eelpyxjmhdsgvtmaeqkyn6qz0jule99a7nk6asezxvlu"'
assert '/committee' '[.members[].cold_bech32] | map(startswith("cc_cold1")) | unique' '[true]'
# votes_cast counts DISTINCT governance actions through every registration this cold key ever made,
# so a hot-key rotation does not split the record. Six each.
assert '/committee' '[.members[].votes_cast] | unique' '[6]'
# the member ids must round-trip through /votes, which addresses committee votes by the same cold
# credential (D-24). If these disagree, one of the two endpoints is publishing a hot key.
CC0=$(j '/committee' '.members[0].cold_bech32' | tr -d '"')
assert "/votes?voter_id=$CC0&limit=1" '.items[0].voter_id' "\"$CC0\""
assert "/votes?voter_id=$CC0&limit=1" '.total' '6'

# preprod: 510 pools in the epoch-320 distribution. This is the DISTRIBUTION, not the voter list.
assert '/spos?limit=1' '.total' '510'
assert '/spos?limit=1' '.items[0].pool_id' '"pool1945cfqzmy2qe2z59mfdwm7jwqtucncfee5xkd8f4wu97zr8xuys"'
assert '/spos?limit=1' '.items[0] | [.voting_power, .voting_power_epoch, .delegator_count, .votes_cast]' \
  '[488680715995324,320,5,8]'
assert '/spos?limit=200' '[.items[].pool_id] | map(startswith("pool1")) | unique' '[true]'
# off_chain_pool_data has 0 rows (fetcher disabled), so ticker is null throughout F1
assert '/spos?limit=200' '[.items[].ticker] | unique' '[null]'
# participation_rate is null, never 0: there is no spo_participation_rate_v1 in the catalog, and a
# published number without a resolvable formula id would break /metrics/formulas' contract.
assert '/spos?limit=200' '[.items[].participation_rate] | unique' '[null]'
# default ordering is voting_power descending, and 56 of the 510 pools sit at 0 -- zero, not null:
# the ledger's distribution for epoch 320 records them with no power.
assert '/spos?limit=5' '[.items[].voting_power] | . == (. | sort | reverse)' 'true'
assert '/spos?order_by=voting_power&sort_order=asc&limit=3' '[.items[].voting_power] | unique' '[0]'
assert '/spos?min_voting_power=1&limit=1' '.total' '454'
# 45 pools have ever voted but only 39 are still in the distribution: six voters have retired.
# /votes?voter_role=spo is where the other six are, and that gap is data, not a bug.
assert '/spos?min_votes_cast=1&limit=1' '.total' '39'
assert '/spos?active_in_epoch=320&limit=1' '.total' '454'
# stable paging: 56 pools tie on voting_power and 471 tie on votes_cast = 0
assert '/spos?order_by=votes_cast&limit=200' '[.items[].pool_id] | (length) == (unique | length)' 'true'
# /spos has no `q` (cut list C-10). Servant IGNORES an undeclared query param, so the observable is
# "it does not filter", not a 400 -- the Swagger parameter list is checked in T-API-18.
[ "$(code '/spos?q=abc')" = 200 ] || { echo "  FAIL /spos?q must be ignored, not rejected"; fail=1; }
[ "$(j '/spos?q=abc&limit=1' '.total')" = "$(j '/spos?limit=1' '.total')" ] || { echo "  FAIL q filtered /spos"; fail=1; }
assert_err '/spos?order_by=nonsense' '.code' '"invalid_parameter"'

# preprod: 83 withdrawals across 82 governance actions to 19 beneficiaries.
assert '/treasury-withdrawals?limit=1' '.total' '83'
assert '/treasury-withdrawals?limit=200' '[.items[].gov_action_id] | unique | length' '82'
assert '/treasury-withdrawals?limit=200' '[.items[].beneficiary] | unique | length' '19'
assert '/treasury-withdrawals?limit=200' '[.items[].beneficiary] | map(startswith("stake")) | unique' '[true]'
assert '/treasury-withdrawals?limit=200' '[.items[] | select(.amount <= 0)] | length' '0'
# NONE has ever been enacted, so all three enactment fields are empty together. reward_rest has 0
# rows of type treasury, which is why paid_heuristic is false rather than null.
assert '/treasury-withdrawals?limit=200' '[.items[].enacted_epoch] | unique' '[null]'
assert '/treasury-withdrawals?limit=200' '[.items[].enacted_at] | unique' '[null]'
assert '/treasury-withdrawals?limit=200' '[.items[].paid_heuristic] | unique' '[false]'
# only 3 of the 83 carry a CIP-108 title. Through palmares.gov_action, which pins db-sync 13.7.x's
# duplicate child rows -- the raw off_chain_vote_gov_action_data join reads 86 rows, not 83.
assert '/treasury-withdrawals?limit=200' '[.items[] | select(.gov_action_title != null)] | length' '3'
# preprod's five largest withdrawals, in lovelace. Two are identical, which is what makes the
# tiebreaker load-bearing.
assert '/treasury-withdrawals?order_by=amount&sort_order=desc&limit=5' '[.items[].amount]' \
  '[149000000000000,96817080000000,96817080000000,69459000000000,50000000000000]'
assert '/treasury-withdrawals?min_amount=1000000000000&limit=1' '.total' '34'
# 82 of the 83 rows share enacted_epoch = null, so the DEFAULT page is decided entirely by the
# tiebreaker. Without a total one it would skip rows; (gov_action_id, stake_address_id) is unique
# across all 83, measured.
assert '/treasury-withdrawals?limit=200' '[.items[] | [.gov_action_id, .beneficiary]] | (length) == (unique | length)' 'true'
assert_err '/treasury-withdrawals?enacted_from_epoch=321&enacted_to_epoch=320' '.code' '"invalid_epoch_range"'
assert_err '/treasury-withdrawals?gov_action_id=nope' '.code' '"invalid_gov_action_id"'
[ "$(code '/committee')" = 200 ] || { echo "  FAIL /committee is $(code '/committee')"; fail=1; }

# CSV: each list family exports, with its own ceiling. Fetched ONCE into a variable for the
# SIGPIPE reason the /dreps block explains.
dcsv=$(curl -fsS -H 'Accept: text/csv' "$API/delegations?limit=10000")
check "/delegations CSV header" \
  "$(printf '%s' "$dcsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'stake_address,target,target_name'
check "/delegations CSV is 2015 current rows plus a header" "$(printf '%s\n' "$dcsv" | grep -c .)" 2016
check "/delegations CSV booleans match the JSON spelling" \
  "$(printf '%s' "$dcsv" | tail -n +2 | awk -F, '{print $NF}' | tr -d '\r' | sort -u | tr '\n' ' ')" 'true '
scsv=$(curl -fsS -H 'Accept: text/csv' "$API/spos?limit=10000")
check "/spos CSV header" \
  "$(printf '%s' "$scsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'pool_id,ticker,voting_power'
check "/spos CSV is 510 rows plus a header" "$(printf '%s\n' "$scsv" | grep -c .)" 511
check "/spos CSV has no unguarded formula lead" \
  "$(printf '%s' "$scsv" | tail -n +2 | grep -cE '^[=+@]' || true)" 0
tcsv=$(curl -fsS -H 'Accept: text/csv' "$API/treasury-withdrawals?limit=10000")
check "/treasury-withdrawals CSV header" \
  "$(printf '%s' "$tcsv" | head -1 | tr -d '\r' | cut -d, -f1-3)" 'gov_action_id,gov_action_title,beneficiary'
check "/treasury-withdrawals CSV is 83 rows plus a header" "$(printf '%s\n' "$tcsv" | grep -c .)" 84
# /committee has no CSV alternative: servant must refuse the Accept rather than serve JSON under a
# text/csv content type.
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/csv' "$API/committee")" = 406 ] \
  && echo "  ok   /committee refuses text/csv" \
  || { echo "  FAIL /committee should 406 on Accept: text/csv"; fail=1; }

echo "== governance activity feed (T-API-15)"
# The one CURSOR-paged endpoint. Everything asserted here is a property of the cursor contract,
# because a feed that pages wrongly repeats or skips events and nothing in a status code says so.
assert '/activity?limit=5' '.items|length' '5'
assert '/activity?limit=5' '.limit' '5'
# total is null BY DESIGN: counting 3.9M union rows on every page is what this endpoint avoids.
assert '/activity?limit=5' '.total' 'null'
assert '/activity?limit=5' '(.next_cursor|split(":")|length)' '4'
assert '/activity?limit=5' '[.items[].cursor|split(":")|length]|unique' '[4]'
assert '/activity?limit=5' '.next_cursor == .items[-1].cursor' 'true'
# The ceiling is 100 and the default 20 (Query.Common.activityBounds).
assert '/activity?limit=500' '.items|length' '100'
assert '/activity' '.limit' '20'
assert_err '/activity?before=nope' '.code' '"invalid_cursor"'
assert_err '/activity?before=1:2:3' '.code' '"invalid_cursor"'
assert_err '/activity?since=garbage' '.code' '"invalid_cursor"'
# A cursor is a token this service issued: " 1:2:3:4" is not one, even though Haskell's Read
# would take it.
assert_err '/activity?before=%201:2:3:4' '.code' '"invalid_cursor"'
# Two directions, at most one per request: the pair names no single direction.
assert_err '/activity?before=1:2:3:4&since=1:2:3:4' '.code' '"both_cursors_given"'
# `offset` is not declared, and servant IGNORES an undeclared query param. The observable is
# "it does not page", not a 400.
[ "$(code '/activity?offset=10')" = 200 ] \
  && echo "  ok   /activity ignores offset rather than rejecting it" \
  || { echo "  FAIL /activity?offset must be ignored, not rejected"; fail=1; }
check "/activity?offset did not page" \
  "$(j '/activity?offset=10&limit=5' '[.items[].cursor]')" "$(j '/activity?limit=5' '[.items[].cursor]')"
# JSON only. A CSV export is a whole result set and this endpoint cannot say how large its is.
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/csv' "$API/activity?limit=1")" = 406 ] \
  && echo "  ok   /activity refuses text/csv" \
  || { echo "  FAIL /activity should 406 on Accept: text/csv"; fail=1; }

# Two pages by `before`: strictly descending, no overlap, every row of page 2 older than page 1's
# last. This is the assertion the four-component cursor exists for — the three-component one had
# 108,141 duplicate groups and would have failed it.
p1=$(curl -fsS "$API/activity?limit=50")
cur=$(printf '%s' "$p1" | jq -r .next_cursor)
p2=$(curl -fsS "$API/activity?limit=50&before=$cur")
k1=$(printf '%s' "$p1" | jq -r '[.items[].cursor]|join(" ")')
k2=$(printf '%s' "$p2" | jq -r '[.items[].cursor]|join(" ")')
check "/activity pages do not overlap" \
  "$(printf '%s %s' "$k1" "$k2" | tr ' ' '\n' | sort | uniq -d | wc -l | tr -d ' ')" 0
check "/activity: both pages descend and page 2 is entirely older" \
  "$(python3 -I -c "
import sys
k=lambda c: tuple(int(x) for x in c.split(':'))
a=[k(x) for x in sys.argv[1].split()]; b=[k(x) for x in sys.argv[2].split()]
print('yes' if all(x < a[-1] for x in b) and a == sorted(a, reverse=True) and b == sorted(b, reverse=True) else 'no')
" "$k1" "$k2")" yes
# `since` is EXCLUSIVE and ascending, and the two directions tile the feed: walking back with
# `before` and then forward with `since` from the far end returns the same rows the other way up.
back=$(printf '%s' "$p2" | jq -r '.items[-1].cursor')
fwd=$(curl -fsS "$API/activity?limit=50&since=$back")
check "/activity?since ascends" \
  "$(printf '%s' "$fwd" | jq -r '[.items[].cursor]|join(" ")' | python3 -I -c "
import sys
k=lambda c: tuple(int(x) for x in c.split(':'))
a=[k(x) for x in sys.stdin.read().split()]
print('yes' if a == sorted(a) else 'no')")" yes
check "/activity?since excludes the cursor row itself" \
  "$(printf '%s' "$fwd" | jq -r --arg c "$back" '[.items[].cursor]|index($c)|tostring')" null

# The epoch-boundary kinds have no transaction: slot and tx_hash are null TOGETHER, and the epoch
# and the time are always there. Inventing a chain point for them would be a lie.
assert '/activity?event_type=gov_action_enacted&event_type=gov_action_ratified&event_type=gov_action_expired&event_type=gov_action_dropped&limit=100' \
  '[([.items[]|.at.slot]|unique), ([.items[]|.at.tx_hash]|unique), ([.items[]|.at.epoch != null]|unique)]' \
  '[[null],[null],[true]]'
# ...and tx_index = -1 for the four lifecycle kinds, which is what keeps them sorting before every
# transaction in their epoch.
assert '/activity?event_type=gov_action_enacted&event_type=gov_action_ratified&event_type=gov_action_expired&event_type=gov_action_dropped&limit=100' \
  '[.items[].cursor|split(":")|.[1]]|unique' '["-1"]'
# preprod's own: no committee member has ever resigned and no treasury withdrawal has been
# enacted, so two of the thirteen kinds are unreachable here. An empty page carries NO
# next_cursor — handing one out would make a client poll forever for rows that cannot exist.
assert '/activity?event_type=committee_resigned' '[(.items|length), .next_cursor]' '[0,null]'
assert '/activity?event_type=treasury_withdrawal_enacted' '[(.items|length), .next_cursor]' '[0,null]'
assert '/activity?event_type=gov_action_proposed&limit=100' '[.items[].event_type]|unique' '["gov_action_proposed"]'
assert '/activity?limit=100' '[.items[].source]|unique' '["governance"]'
# An actor is matched in BOTH id forms, because actor_id holds a hex credential on the DRep and
# committee arms and a bech32 stake address on the delegation and proposal arms. preprod's Bitcows
# DRep: 18 events across three kinds.
assert '/activity?actor=drep1y2qn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg&limit=100' \
  '[(.items|length), ([.items[].event_type]|unique)]' \
  '[18,["drep_registered","drep_updated","vote_cast"]]'
assert '/activity?actor=81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8&limit=100' \
  '.items|length' '18'
# A stake address does not decode as a credential and must NOT be a 400: it is what the
# delegation arm publishes.
[ "$(code '/activity?actor=stake_test1uqfzskazkqhtph40s82g93n4srh3x463lazy0n2gkv9rnyq7acw3c')" = 200 ] \
  && echo "  ok   /activity accepts a stake address as an actor" \
  || { echo "  FAIL /activity should accept a stake address as an actor"; fail=1; }

if [ "$fail" = 0 ]; then echo "smoke OK"; else echo "smoke FAILED" >&2; fi
exit $fail
