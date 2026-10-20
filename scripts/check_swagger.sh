#!/usr/bin/env bash
# F1 check 12's parity half: the Swagger document says what the API actually serves.
#
# The CI step beside this one regenerates the document and diffs it, which catches DRIFT — the file
# falling behind the code. It cannot catch the document and the code agreeing on something wrong,
# so the contract's load-bearing facts are asserted here by value.
#
# Everything checked is something a client codegen or a reader depends on: the path set, the error
# enum it branches on, the parameters that exist and the ones that deliberately do not.
#
# Usage: scripts/check_swagger.sh [path-to-swagger.json]
set -euo pipefail

DOC="${1:-docs/generated/swagger/query-swagger-api.json}"
fail=0

# Each check is a jq predicate. On failure the predicate itself is printed, plus whatever it
# evaluated to — `jq -e` exits non-zero on false OR null, so a missing key reads as a failure
# rather than as a pass, which is the behaviour this wants.
check() {
  if jq -e "$2" "$DOC" >/dev/null; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"
    echo "       $2 => $(jq -c "$2" "$DOC" 2>&1 | head -1)"
    fail=1
  fi
}

echo "== swagger metadata"
check "version is 1.0.0" '.info.version == "1.0.0"'
# DEVIATION from the plan, which pinned "Cardano Governance Registry Query API". The project is
# named palmares and the title is what a reader sees first; the plan's title predates the name.
check "title is the product's name" '.info.title == "Palmares Query API"'
check "license is Apache-2.0" '.info.license.name == "Apache-2.0"'
# `host` unset on purpose: the document is served from whatever origin answers, and a baked-in
# host is the field that makes a generated client point at the wrong deployment.
check "host is not baked in" '.host == null'

echo "== the path set"
# 22 documented paths: the 18 governance routes + /health /ready /status /metrics/formulas. The two
# /pages/… aliases are paths of their own; /swagger-api.json and /swagger-ui are the UI, not
# CoreFunctionAPI.
check "22 paths" '[.paths | keys[]] | length == 22'
for p in /health /ready /status /metrics/formulas /dreps /gov-actions /votes /activity /search \
  /delegations /committee /spos /treasury-withdrawals /pages/drep-explorer /pages/dashboard; do
  check "$p is documented" ".paths | has(\"$p\")"
done

echo "== the error contract"
# Nothing in the served API type mentions ApiError — servant types the success body only — so both
# of these are declared explicitly in apiSwagger. Without them a client cannot discover a single
# error code from the document, which is the one thing it must branch on.
check "ApiError is defined" '.definitions | has("ApiError")'
check "ErrorCode has all 24 codes" '.definitions.ErrorCode.enum | length == 24'
check "codes are snake_case tags" '.definitions.ErrorCode.enum | index("invalid_cursor") != null'
check "both_cursors_given is published" '.definitions.ErrorCode.enum | index("both_cursors_given") != null'
for s in 400 404 503; do
  check "the global $s response carries the ApiError schema" \
    "[.paths[].get.responses[\"$s\"].schema[\"\$ref\"]] | unique == [\"#/definitions/ApiError\"]"
done

echo "== parameters that must exist, and ones that must not"
# Accept is a HEADER parameter and must be optional: it is how a handler learns the negotiated
# content type for its page bounds, not something a client has to send.
check "Accept on /dreps is optional" \
  '.paths["/dreps"].get.parameters | map(select(.name == "Accept")) | .[0].required == false'
# q is cut on /spos only (cut list C-10) and kept on the other four list endpoints.
check "/spos has no q" '[.paths["/spos"].get.parameters[].name] | index("q") == null'
check "/dreps has q" '[.paths["/dreps"].get.parameters[].name] | index("q") != null'
# /activity is the one cursor-paged endpoint: offset must not be declared on it, and the two
# direction cursors must be.
check "/activity declares no offset" '[.paths["/activity"].get.parameters[].name] | index("offset") == null'
check "/activity declares before and since" \
  '[.paths["/activity"].get.parameters[].name] | (index("before") != null) and (index("since") != null)'
check "/activity serves JSON only" \
  '.paths["/activity"].get.produces == ["application/json;charset=utf-8"]'
# Every other list endpoint exports CSV, and a generated client needs to see both.
for p in /dreps /gov-actions /votes /delegations /spos /treasury-withdrawals; do
  check "$p offers JSON and CSV" \
    ".paths[\"$p\"].get.produces | (index(\"application/json;charset=utf-8\") != null) and (index(\"text/csv;charset=utf-8\") != null)"
done

echo "== enums a client switches on"
check "VoterRole is the wire spelling" \
  '.definitions.VoterRole.enum == ["drep","spo","constitutional_committee"]'
check "ActivityEventType has all thirteen kinds" '.definitions.ActivityEventType.enum | length == 13'
# ONE source in F1, not two. Every arm of palmares.activity publishes 'governance'; 'attestation'
# arrives with the attestation schema, and this assertion is what will have to be updated when it
# does — deliberately, rather than the enum growing unnoticed.
check "ActivitySource is governance alone in F1" '.definitions.ActivitySource.enum == ["governance"]'

if [ "$fail" = 0 ]; then echo "swagger OK"; else echo "swagger FAILED" >&2; fi
exit $fail
