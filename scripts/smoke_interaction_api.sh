#!/usr/bin/env bash
# The write API answered, and refused what it is supposed to refuse.
#
# Deliberately NOT a transaction test: building one needs a funded wallet, a provider and five
# resolvable reference scripts, which is an environment this script cannot assert its way into.
# What it does assert is everything that holds with no wallet at all — the status facts, the auth
# boundary, and the two refusals that are product decisions rather than accidents:
#
#   * no admin action is accepted in a request body, through any route, including /build-tx;
#   * /status answers 200 with the provider and the oracle's pause flag even when the chain reads
#     fail, because a status route that fails when the thing it reports on is broken is the defect
#     it was written against.
#
# Usage: PALMARES_API=http://localhost:8082 BASIC_USER=… BASIC_PASS=… scripts/smoke_interaction_api.sh
set -euo pipefail

API="${PALMARES_API:-http://localhost:8082}"
AUTH="${BASIC_USER:-}:${BASIC_PASS:-}"
fail=0

# 2xx only: -f makes curl fail on a 4xx so a wrong status cannot read as a wrong value.
j() { curl -fsS -H 'Accept: application/json' "$API$1" | jq -c "$2"; }

# `|| true`: without it `set -e` aborts the run on the first failing assertion instead of recording
# it and carrying on, which is the difference between one finding and a full report.
assert() {
  got=$(j "$1" "$2" || true)
  if [ "$got" = "$3" ]; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2 => $got (want $3)"; fail=1; fi
}

check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 => $2 (want $3)"; fail=1; fi; }

# Status code of an unauthenticated GET.
code() { curl -s -o /dev/null -w '%{http_code}' "$API$1"; }

# Status code of an authenticated POST with a JSON body.
post_code() {
  curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -H 'Content-Type: application/json' -d "$2" "$API$1"
}

# Body of an authenticated POST — 4xx bodies included, so `-f` is deliberately absent.
post_body() {
  curl -sS -u "$AUTH" -H 'Content-Type: application/json' -d "$2" "$API$1"
}

echo "== probes and status"
assert /health '.status' '"healthy"'
assert /health '.service' '"interaction-api"'
# The five fields /status exists for. Asserted as a SET, because the whole point is that an operator
# can see the provider and the pause flag at all — /health reports healthy without either.
assert /status '[keys[]]|sort|join(",")' '"deployed_scripts,network,oracle_paused,provider,version"'
assert /status '.provider|type' '"string"'
# The provider family only: a token is Confidential and a socket path or Kupo URL is not, and this
# route is unauthenticated.
assert /status '.provider|test("^(node-kupo|ogmios-kupo|maestro|blockfrost)$")' 'true'
assert /status '.network|test("^(mainnet|preprod|preview|legacy|privnet)$")' 'true'
# A boolean, not null: `null` is the honest answer when the oracle cannot be read at all, so against
# a deployment that is supposed to be serving writes, null here IS the finding.
assert /status '.oracle_paused|type' '"boolean"'
assert /status '.deployed_scripts' 'true'

echo "== the published document"
assert /swagger-api.json '.info.title' '"Palmares Interaction API"'
assert /swagger-api.json '.info.version' '"3.0.0"'
assert /swagger-api.json '[.paths|keys[]]|length' '12'
for p in /claim-profile /update-profile /issue-attestation /accept-attestation /open-dispute \
  /resolve-dispute /build-tx /submit-tx /status; do
  assert /swagger-api.json "(.paths|has(\"$p\"))" 'true'
done
# The sum-encoding fix, on the document a client actually downloads: swagger2's generic instance
# publishes `{"<Constructor>": {…}}` with maxProperties 1, while aeson reads `{"tag": …}`.
assert /swagger-api.json '.definitions.ActionType|has("maxProperties")' 'false'
assert /swagger-api.json '.definitions.ActionType.properties|has("tag")' 'true'
assert /swagger-api.json '.definitions.ProfileActionType.properties|has("tag")' 'true'

echo "== the auth boundary"
check "/build-tx without credentials is 401" "$(code /build-tx)" "401"
check "/claim-profile without credentials is 401" "$(code /claim-profile)" "401"
# The probes and /status are public on purpose: a k8s probe has no credentials, and an operator
# diagnosing a refused write should not need any either.
check "/health is public" "$(code /health)" "200"
check "/status is public" "$(code /status)" "200"

echo "== admin actions are not on the HTTP surface"
# `Interaction` and `UserAddresses` are derived with aeson's DEFAULT options, so their wire keys are
# camelCase while every *Request type on this API is snake_case. Measured in the generated document,
# not assumed. A real address goes in `changeAddress` on purpose: an unparseable one would make the
# body fail for the wrong reason and the refusals below would pass vacuously.
ADDR="00e1cbb80db89e292269aeb93ec15eb963dda5176b66949fe1c2a6a38d1b930e9f7add78a174a21000e989ff551366dcd127028cb2aa39f616"
wrap() { echo "{\"action\":{\"tag\":\"AdminAction\",\"contents\":$1},\"userAddresses\":{\"usedAddresses\":[],\"changeAddress\":\"$ADDR\"},\"recipient\":null}"; }

# Every constructor, including the two that were already refused, so the assertion is about the
# TYPE and not about four of its arms. Each must be a 400 from the parser, never a built transaction.
for a in '{"tag":"PauseProtocolAction"}' '{"tag":"UnpauseProtocolAction"}' \
  '{"tag":"SetMinUTxOValueAction","lovelace":1000000}' \
  '{"tag":"SetDisputeDepositAction","lovelace":5000000}' \
  '{"tag":"RotateAdminAction"}' '{"tag":"SetFeesAction"}'; do
  check "/build-tx refuses $a" "$(post_code /build-tx "$(wrap "$a")")" "400"
done
# And the refusal says where the action belongs, because a client that gets a 400 with no direction
# will try again with the same body. This is also what keeps the loop above honest: a body rejected
# for some other reason is also a 400, and only the message says which refusal fired.
got=$(post_body /build-tx "$(wrap '{"tag":"PauseProtocolAction"}')" || true)
case "$got" in
  *"admin CLI"*) echo "  ok   the refusal names the admin CLI" ;;
  *) echo "  FAIL the refusal does not name the admin CLI => $got"; fail=1 ;;
esac

echo
if [ "$fail" = 0 ]; then echo "all checks passed"; else echo "FAILURES above"; exit 1; fi
