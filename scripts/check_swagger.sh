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
check "version is 1.2.0" '.info.version == "1.2.0"'
# D-A. A client that SWITCHES on the verdict gains a case here, and one that renders `expired` as a
# finding is wrong — which is the whole reason the value is in the published enum rather than left
# to a null and a comment.
check "DisputeVerdict publishes expired beside the two findings" \
  '(.definitions.DisputeVerdict.enum | sort) == ["expired","rejected","upheld"]'
# DEVIATION from the plan, which pinned "Cardano Governance Registry Query API". The project is
# named palmares and the title is what a reader sees first; the plan's title predates the name.
check "title is the product's name" '.info.title == "Palmares Query API"'
check "license is Apache-2.0" '.info.license.name == "Apache-2.0"'
# `host` unset on purpose: the document is served from whatever origin answers, and a baked-in
# host is the field that makes a generated client point at the wrong deployment.
check "host is not baked in" '.host == null'

echo "== the path set"
# 29 documented paths: the 18 governance routes + /health /ready /status /metrics/formulas + the 7
# attestation read routes T-ATTEST-9 landed. The two /pages/… aliases are paths of their own;
# /swagger-api.json and /swagger-ui are the UI, not CoreFunctionAPI.
#
# The COUNT and the names are both checked, because they catch different mistakes. A route that
# disappears fails the count even if nobody thought to name it below, and a route that is renamed
# fails its own line while the count still passes. Updating this number is a deliberate act: it is
# how a route added or removed shows up as a reviewed diff rather than as nothing at all.
check "29 paths" '[.paths | keys[]] | length == 29'
for p in /health /ready /status /metrics/formulas /dreps /gov-actions /votes /activity /search \
  /delegations /committee /spos /treasury-withdrawals /pages/drep-explorer /pages/dashboard \
  /profiles /profiles/by-credential/{credential} /profiles/{profile-id} \
  /profiles/{profile-id}/attestations /attestations /attestations/{attestation-id} /disputes; do
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

echo "== the attestation read surface"
# JSON ONLY on all seven, and that is a DECISION rather than an omission: every governance list
# serves CSV, these do not. A claim->attest->verify flow pages and does not export, and the orphan
# `ToNamedRecord`/`DefaultOrdered` instances CSV needs would be ~150 lines of header-order
# boilerplate in `Query/Csv.hs`. Pinned so that adding CSV later is a reviewed diff here too.
for p in /profiles /profiles/{profile-id} /profiles/by-credential/{credential} \
  /profiles/{profile-id}/attestations /attestations /attestations/{attestation-id} /disputes; do
  check "$p serves JSON only" \
    ".paths[\"$p\"].get.produces == [\"application/json;charset=utf-8\"]"
done

# `credential_is_script` is the field that makes the strict CIP-129 codec visible to a client. The
# lookup refuses CIP-105 and bare hex because neither carries a header byte and `drep` is the HRP
# for both kinds; this field is that byte READ BACK, never guessed. A client that cannot see it
# would have to re-derive the key/script distinction from an id it was not given.
check "AttestProfileRow publishes credential_is_script" \
  '.definitions.AttestProfileRow.properties | has("credential_is_script")'
check "the credential lookup takes a path parameter named credential" \
  '[.paths["/profiles/by-credential/{credential}"].get.parameters[] | select(.in == "path") | .name] == ["credential"]'

# The five attestation kinds, as wire spellings. Same check as ActivityEventType below and for the
# same reason: a client switches on these, so a sixth kind added without a published enum entry is
# a client that cannot handle it.
# Seven since ADR 0003: a credential binding is an attestation, so `credential_claim` and
# `credential_withdrawal` are kinds. Asserted as a SET and not a count, because a count would stay
# green if a kind were renamed — and the names are what a client branches on.
check "AttestationType publishes all seven kinds" \
  '(.definitions.AttestationType.enum | sort) == ["affiliation","audit_passed","credential_claim","credential_withdrawal","endorsement","milestone_delivered","role_held"]'
check "AttestationType is the wire spelling" \
  '.definitions.AttestationType.enum | index("milestone_delivered") != null'

# TWO indexers, published separately. `governance` is db-sync's lag; `attest_lag_seconds` is the
# attestation projector's. Either can be dead while the other is current, so a client reading only
# `governance` would take a fresh governance lag as evidence about an attestation it just wrote —
# the same conflation `scripts/smoke_attest_flow.sh` works around by polling for the projection.
check "/status publishes the attestation projector's lag separately" \
  '.definitions.StatusResponse.properties | has("attest_lag_seconds")'
# NOT required, because the service answers `null` when it has no evidence of a projector rather
# than a zero, and a zero would read as "perfectly current".
#
# OPTIONAL IS NOT NULLABLE, and this check asserts only the first. In Swagger 2.0, absence from
# `required` permits the key to be OMITTED; it does not sanction a `null` value, and expressing that
# needs `x-nullable`. The generated document has no `x-nullable` anywhere — every `Maybe` field in
# it has this same shape (`DRepSummary.given_name`, `active_until_epoch`) — so this is a
# document-wide gap and not one this field introduced. Adding the key here alone would make the
# document inconsistent with itself, so what pins the real wire contract is the encoder test in
# `UnitTests.GovDto`: the key is always PRESENT, with value `null`.
#
# Asserted as the WHOLE required set rather than as `index(…) == null`, which would also pass if the
# `required` array disappeared entirely: `null | index("x")` is null in jq, and null == null is true.
check "attest_lag_seconds is not in required (optional; nullability is pinned by the encoder test)" \
  '.definitions.StatusResponse.required == ["network","governance","epoch_params"]'

echo "== enums a client switches on"
check "VoterRole is the wire spelling" \
  '.definitions.VoterRole.enum == ["drep","spo","constitutional_committee"]'
check "ActivityEventType has all thirteen kinds" '.definitions.ActivityEventType.enum | length == 13'
# The third registered status, by value and in order. `unknown` is the one a client is most likely
# to have no branch for, because it did not exist when the enum was first published: it means
# "registered, and the ledger recorded no activity deadline we can read", which is 90 of preprod's
# 294 registered DReps. A client that treats it as `inactive` is making the claim we stopped making.
check "DRepStatus carries the third registered status" \
  '.definitions.DRepStatus.enum == ["active","inactive","unknown","retired","reserved"]'
# ONE source in F1, not two. Every arm of palmares.activity publishes 'governance'; 'attestation'
# arrives with the attestation schema, and this assertion is what will have to be updated when it
# does — deliberately, rather than the enum growing unnoticed.
check "ActivitySource is governance alone in F1" '.definitions.ActivitySource.enum == ["governance"]'

if [ "$fail" = 0 ]; then echo "swagger OK"; else echo "swagger FAILED" >&2; fi
exit $fail
