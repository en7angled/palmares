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
# Pinned so a version bump arrives as a reviewed diff rather than as nothing. 1.6.0 adds `is_final`
# on `/votes` — the parameter that turns 3,244,723 rows into 931 — plus `GET /disputes/{id}`,
# `GET /profiles/by-user-token/{id}`, `x-nullable` on all 127 nullable properties, the real
# `limit`/`offset` bounds, and a `{code, message}` body on the 405 and 406 the router answered empty.
check "version is 1.6.0" '.info.version == "1.6.0"'
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
# 31 documented paths: the 18 governance routes + /health /ready /status /metrics/formulas + the 9
# attestation read routes. The two /pages/… aliases are paths of their own; /swagger-api.json and
# /swagger-ui are the UI, not CoreFunctionAPI.
#
# 29 -> 31: `/profiles/by-user-token/{asset-class}` and `/disputes/{dispute-id}`. The first is the
# only question a connected wallet can ask on its own — it holds the CIP-68 USER token and every
# other route here is keyed by the REFERENCE token — and the second gives a dispute a URL, which it
# had none of: `/disputes?target=` needs the attestation id as well, and `/attestations/{id}`
# inlines at most 50, so a dispute past that bound was unaddressable.
#
# The COUNT and the names are both checked, because they catch different mistakes. A route that
# disappears fails the count even if nobody thought to name it below, and a route that is renamed
# fails its own line while the count still passes. Updating this number is a deliberate act: it is
# how a route added or removed shows up as a reviewed diff rather than as nothing at all.
check "31 paths" '[.paths | keys[]] | length == 31'
for p in /health /ready /status /metrics/formulas /dreps /gov-actions /votes /activity /search \
  /delegations /committee /spos /treasury-withdrawals /pages/drep-explorer /pages/dashboard \
  /profiles /profiles/by-credential/{credential} /profiles/by-user-token/{asset-class} \
  /profiles/{profile-id} \
  /profiles/{profile-id}/attestations /attestations /attestations/{attestation-id} /disputes \
  /disputes/{dispute-id}; do
  check "$p is documented" ".paths | has(\"$p\")"
done

echo "== a list route's items are its own DTO"
# The gate asserted paths, parameters, `produces` and enums, and never this — so a `ToSchema (Page a)`
# instance that named every page after the DATATYPE and ignored its argument went unnoticed: all 15
# list routes `$ref`-ed one `#/definitions/Page` whose `items` were whichever element type registered
# last (`DisputeRow`). A generated client typed `/dreps` as a list of disputes. Three routes with
# three different element types is enough to catch a collision; the count catches a route that stops
# paging at all.
check "13 per-element page schemas" '[.definitions | keys[] | select(startswith("Page_"))] | length == 13'
for pair in "/dreps:DRepSummary" "/gov-actions:GovActionSummary" "/votes:VoteRecord" "/disputes:DisputeRow"; do
  p="${pair%%:*}"; dto="${pair##*:}"
  check "$p pages $dto" \
    ".paths[\"$p\"].get.responses[\"200\"].schema[\"\$ref\"] == \"#/definitions/Page_$dto\" and (.definitions[\"Page_$dto\"].properties.items.items[\"\$ref\"] == \"#/definitions/$dto\")"
done

echo "== the error contract"
# Nothing in the served API type mentions ApiError — servant types the success body only — so both
# of these are declared explicitly in apiSwagger. Without them a client cannot discover a single
# error code from the document, which is the one thing it must branch on.
check "ApiError is defined" '.definitions | has("ApiError")'
# 24 -> 27. `invalid_credential` is /profiles/by-credential's own 400, which used to answer
# `invalid_drep_id` ("Not a DRep identifier") for a perfectly good committee credential;
# `method_not_allowed` and `not_acceptable` are the two the ROUTER produces, which were being served
# with an empty body and no content type at all.
check "ErrorCode has all 27 codes" '.definitions.ErrorCode.enum | length == 27'
check "codes are snake_case tags" '.definitions.ErrorCode.enum | index("invalid_cursor") != null'
check "both_cursors_given is published" '.definitions.ErrorCode.enum | index("both_cursors_given") != null'
check "the three codes added for the refusal contract are published" \
  '.definitions.ErrorCode.enum | (index("invalid_credential") != null) and (index("method_not_allowed") != null) and (index("not_acceptable") != null)'
# 405, 406 and 500 join the three that were here. Each is a status this service really answers with
# and did not declare: the first two come out of servant's router (no ErrorFormatters hook exists
# for either, so `refusedRequestMiddleware` carries the body) and the third is warp's last resort,
# pointed at `internalErrorResponse` in Main.
#
# 502 IS DELIBERATELY ABSENT from this list, where the interaction document's section below asserts
# it on every operation. Nothing in query-api can produce one: no ErrorCode maps to 502 and the
# service holds no provider to fail against. A 502 a client sees here came from the proxy in front,
# with the proxy's own body. Declaring it would repeat exactly the mistake `invalid_asset_class`
# was — a published case nothing can reach.
for s in 400 404 405 406 500 503; do
  check "the global $s response carries the ApiError schema" \
    "[.paths[].get.responses[\"$s\"].schema[\"\$ref\"]] | unique == [\"#/definitions/ApiError\"]"
done
check "query-api declares no 502: it has no provider to fail against" \
  '[.paths[].get.responses | keys[]] | unique | index("502") == null'

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
  /profiles/by-user-token/{asset-class} \
  /profiles/{profile-id}/attestations /attestations /attestations/{attestation-id} /disputes \
  /disputes/{dispute-id}; do
  check "$p serves JSON only" \
    ".paths[\"$p\"].get.produces == [\"application/json;charset=utf-8\"]"
done

# The wallet lookup takes a path parameter and takes it as a STRING, which is the decision worth
# pinning: it is the asset class of the CIP-68 USER token, which is well-formed and is NOT a profile
# id, so typing it as GYAssetClass would have let Atlas's parser accept it and then look up a row
# that cannot exist. The handler derives the reference id from it (a four-byte CIP-67 label swap)
# and refuses anything else with 400 `invalid_asset_class` — this route is that code's only
# reachable site in the service.
check "the wallet lookup takes a path parameter named asset-class" \
  '[.paths["/profiles/by-user-token/{asset-class}"].get.parameters[] | select(.in == "path") | .name] == ["asset-class"]'
check "it answers ONE profile, not a page" \
  '.paths["/profiles/by-user-token/{asset-class}"].get.responses["200"].schema["$ref"] == "#/definitions/AttestProfileRow"'
# A bare DisputeRow and not a Page_DisputeRow: it is one record, like /profiles/{profile-id}. The
# assertion is here because `Page_DisputeRow` already exists in the document, so the wrong one of the
# two is a plausible mistake that would still generate a client.
check "the single-dispute route answers a DisputeRow, not a page" \
  '.paths["/disputes/{dispute-id}"].get.responses["200"].schema["$ref"] == "#/definitions/DisputeRow"'

# `credential_is_script` is the field that makes the strict CIP-129 codec visible to a client. The
# lookup refuses CIP-105 and bare hex because neither carries a header byte and `drep` is the HRP
# for both kinds; this field is that byte READ BACK, never guessed. A client that cannot see it
# would have to re-derive the key/script distinction from an id it was not given.
check "AttestProfileRow publishes credential_is_script" \
  '.definitions.AttestProfileRow.properties | has("credential_is_script")'
check "the credential lookup takes a path parameter named credential" \
  '[.paths["/profiles/by-credential/{credential}"].get.parameters[] | select(.in == "path") | .name] == ["credential"]'

# The attestation kinds, as wire spellings. Same check as ActivityEventType below and for the
# same reason: a client switches on these, so a kind added without a published enum entry is
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
# needs `x-nullable`.
#
# THE PARAGRAPH THAT USED TO END HERE said "the generated document has no `x-nullable` anywhere —
# so this is a document-wide gap and not one this field introduced", and concluded that adding the
# key here alone would make the document inconsistent with itself. That was true and it was an
# argument for closing the gap document-wide, which is what `markNullableFields` does: the key is now
# on every property absent from its schema's `required`, this field among them, derived from the same
# `required` list this line asserts. The encoder test in `UnitTests.GovDto` still pins the wire shape
# (the key is always PRESENT, with value `null`); the document now says so too.
#
# Asserted as the WHOLE required set rather than as `index(…) == null`, which would also pass if the
# `required` array disappeared entirely: `null | index("x")` is null in jq, and null == null is true.
check "attest_lag_seconds is not in required (optional, and published x-nullable)" \
  '.definitions.StatusResponse.required == ["network","governance","amber_lag_seconds","ready_max_lag_seconds","epoch_params"]'
check "and it carries x-nullable, like every other Maybe field" \
  '.definitions.StatusResponse.properties.attest_lag_seconds["x-nullable"] == true'

# `CS-07`: the projector's own report, which is what tells "no pipeline here" from "behind". The
# block is optional for the same reason `attest_lag_seconds` is — a governance-only deployment has
# none — and `state` is the field a client branches on, so it is asserted by name.
check "/status publishes the projector's own report" \
  '.definitions.StatusResponse.properties | has("attestation")'
check "the report carries the state a client branches on" \
  '.definitions.AttestationStatus.properties | has("state") and has("last_sync_at") and has("is_ready") and has("policy_id")'
# `GV-23`: four numbers `/ready` already decided with and the body did not publish.
check "/status publishes the readiness inputs, not only the verdict" \
  '.definitions.StatusResponse.properties | has("drep_distr_epoch") and has("amber_lag_seconds") and has("ready_max_lag_seconds") and has("metrics_as_of_epoch")'

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

echo "== nullability"
# Every `Maybe a` in the Haskell must be published nullable, and this is asserted as an INVARIANT in
# both directions rather than as a list of field names: swagger2 omits a field from `required`
# exactly when its type is `Maybe a`, so "absent from required" and "x-nullable" must be the same
# set. Written this way, a DTO that gains a `Maybe` field is covered with no edit here, and a pass
# that over-applied the key — marking a required field nullable — fails the second line.
#
# What this fixed: the document had NO `x-nullable` at all, so a generated TypeScript client typed
# 127 properties across 61 definitions as non-null and threw on the first row that carried a `null`.
# The encoders always emit the key (`UnitTests.GovDto` pins that), so every one of those fields is
# reachable as `null` by a client that did nothing wrong.
check "every property absent from required carries x-nullable" \
  '[.definitions | to_entries[] | (.value.required // []) as $req | (.value.properties // {}) | to_entries[] | .key as $k | select(($req | index($k)) == null) | (.value["x-nullable"] == true)] | all'
check "and no required property carries it" \
  '[.definitions | to_entries[] | (.value.required // []) as $req | (.value.properties // {}) | to_entries[] | .key as $k | select(($req | index($k)) != null) | (.value | has("x-nullable") | not)] | all'
# The COUNT, for the same reason the path count is here: 127 is what was measured, and a change to
# it is a wire-contract change that should arrive as a reviewed diff rather than as nothing.
check "127 nullable properties" \
  '[.definitions | to_entries[] | (.value.required // []) as $req | (.value.properties // {}) | to_entries[] | .key as $k | select(($req | index($k)) == null)] | length == 127'
# Three by name, because they are the ones a client meets first: the envelope's own `total` (null on
# the cursor-paged feed and nowhere else), a scalar inside a row, and a whole nested object behind a
# `$ref` — the case a strict Swagger 2.0 reader may ignore and the reason the document says so.
check "Page.total is nullable" '.definitions.Page_DRepSummary.properties.total["x-nullable"] == true'
check "DRepSummary.given_name is nullable" '.definitions.DRepSummary.properties.given_name["x-nullable"] == true'
check "a \$ref property carries the key beside the reference" \
  '.definitions.DisputeRow.properties.verdict | (has("$ref")) and (.["x-nullable"] == true)'

echo "== the paging bounds this server actually enforces"
# `limit` and `offset` are declared `Int`, so swagger2 derived the Int64 range for every one of them
# — on a parameter clamped to 200 and on an offset REFUSED above 10000. The screen map recorded the
# consequence as advice to the frontend: "Do not generate client validation from the schema", which
# is a published contract telling its only consumer not to read it.
#
# Asserted as an invariant first: no paging parameter may carry the Int64 maximum again, whatever
# its real bound is.
check "no limit or offset publishes the Int64 range" \
  '[.paths[].get.parameters // [] | .[] | select(.name == "limit" or .name == "offset" or .name == "limit_per_group" or .name == "top_limit" or .name == "closing_soon_limit" or .name == "epochs") | .maximum] | all(. != 9223372036854775807)'
# Then by value, one per distinct PageBounds the server holds, so a re-priced endpoint shows up
# here: the list default, /activity's lower pair, the epoch series (default EQUAL to the ceiling,
# because the series is the answer), /search's per-group palette size, and one of the dashboard's
# three.
check "/dreps limit is [1,200] default 50" \
  '.paths["/dreps"].get.parameters | map(select(.name == "limit"))[0] | .minimum == 1 and .maximum == 200 and .default == 50'
check "/activity limit is [1,100] default 20" \
  '.paths["/activity"].get.parameters | map(select(.name == "limit"))[0] | .minimum == 1 and .maximum == 100 and .default == 20'
check "/drep/{id}/power limit is [1,200] default 200" \
  '.paths["/drep/{drep-id}/power"].get.parameters | map(select(.name == "limit"))[0] | .minimum == 1 and .maximum == 200 and .default == 200'
check "/search limit_per_group is [1,20] default 5" \
  '.paths["/search"].get.parameters | map(select(.name == "limit_per_group"))[0] | .minimum == 1 and .maximum == 20 and .default == 5'
check "/pages/dashboard top_limit is [1,50] default 10" \
  '.paths["/pages/dashboard"].get.parameters | map(select(.name == "top_limit"))[0] | .minimum == 1 and .maximum == 50 and .default == 10'
# ONE offset ceiling for the whole API, and it is a rejection rather than a clamp — which is why it
# is published as a maximum at all: a client can validate against it instead of discovering it as a
# 400.
check "every offset is [0,10000] default 0" \
  '[.paths[].get.parameters // [] | .[] | select(.name == "offset") | .minimum == 0 and .maximum == 10000 and .default == 0] | (length > 0) and all'

echo "== the interaction document"
# Nothing in this gate used to look at the WRITE document, and it published `"GPL-3.0 license"` for
# as long as it has existed — regenerated into the committed file on every boot of a service whose
# project is Apache-2.0. Only the facts that are wrong independently of the route set are asserted
# here; the write API's own contract is `scripts/smoke_interaction_api.sh`, which needs it running.
IDOC="docs/generated/swagger/interaction-swagger-api.json"
if [ -f "$IDOC" ]; then
  icheck() {
    if jq -e "$2" "$IDOC" >/dev/null; then
      echo "  ok   $1"
    else
      echo "  FAIL $1"
      echo "       $2 => $(jq -c "$2" "$IDOC" 2>&1 | head -1)"
      fail=1
    fi
  }
  icheck "license is Apache-2.0" '.info.license.name == "Apache-2.0"'
  icheck "title is the product's name" '.info.title == "Palmares Interaction API"'

  # ---- the write API's status contract (added by the write-path gap-closing task) ---------------
  #
  # The gate checked two facts about this document and the facts above are both about `info`, so it
  # still said nothing about what the document promises a CLIENT. It published four statuses — 200,
  # 400, 404, 503 — on a service that also answers 405, 406, 415, 500 and 502, and an undeclared
  # status is a branch a generated client does not have. The 502 is the one that cost something: it
  # is what a submission the node rejected answers, the only write error worth retrying, and a
  # client reading this document had no way to know it existed.
  #
  # Asserted over EVERY operation rather than over one path, which is the half the unit test in
  # `UnitTests.InteractionApi` cannot cheaply do: these five are declared with servant-swagger's
  # `allOperations`, so a change that reaches fourteen of the fifteen is exactly the mistake worth
  # catching. The operation count is in the same predicate so the assertion cannot pass vacuously on
  # a document whose paths failed to generate — `[] | all` is true in jq.
  for s in 200 400 404 405 406 415 500 502 503; do
    icheck "the $s response is declared on every operation" \
      "([.paths[][]] | length == 15) and ([.paths[][] | .responses | has(\"$s\")] | all)"
  done
  # And the set is CLOSED: a sixteenth status declared on every operation but on no route that can
  # return it is the same defect pointing the other way, and this is the line that fails for it.
  icheck "no operation declares a status this service cannot return" \
    '[.paths[][] | (.responses | keys)] | unique == [["200","400","404","405","406","415","500","502","503"]]'

  # ---- the oracle parameters, which are this document's alone -----------------------------------
  #
  # Three frontend gaps were one missing field. Asserted per FIELD and not just on the object,
  # because the failure that produced the gap was a datum whose parameters existed and were
  # published nowhere — an object with four of the seven would read as closed and leave a screen
  # unbuildable. `dispute_timeout_ms` is the one that was missing from the blueprint prose too.
  icheck "/status publishes the oracle's parameters" \
    '.definitions.InteractionStatusResponse.properties.oracle != null'
  for f in dispute_deposit_lovelace dispute_timeout_ms min_utxo_lovelace arbiter admin \
    profile_creation_fee_lovelace attestation_fee_lovelace; do
    icheck "OracleParamsResponse carries $f" \
      ".definitions.OracleParamsResponse.properties | has(\"$f\")"
  done
  # A credential is 28 bytes AND a kind: a UI that offers "sign as admin" to a script credential is
  # offering something that cannot work, so `is_script` is part of the contract, not decoration.
  icheck "a credential publishes both its hash and its kind" \
    '.definitions.CredentialRef.properties | has("hash") and has("is_script")'
  # The same two-way invariant the read document is held to: every optional property carries
  # `x-nullable`, and no required one does. Without it a generated TypeScript client types
  # `oracle` as non-null and throws the first time the oracle cannot be read.
  #
  # Two predicates and not one, and `.key as $k` bound BEFORE the inner `to_entries[]`: inside
  # `index(...)` the `.` is the array being searched, so `$req | index(.key)` evaluates `.key`
  # against `$req` and dies with "Cannot index array with string". Measured — that is exactly how
  # this check failed when it was first written as one expression.
  icheck "every property absent from required carries x-nullable" \
    '[.definitions | to_entries[] | (.value.required // []) as $req | (.value.properties // {}) | to_entries[] | .key as $k | select(($req | index($k)) == null) | (.value["x-nullable"] == true)] | all'
  icheck "and no required property carries it" \
    '[.definitions | to_entries[] | (.value.required // []) as $req | (.value.properties // {}) | to_entries[] | .key as $k | select(($req | index($k)) != null) | (.value | has("x-nullable") | not)] | all'
else
  echo "  --   $IDOC absent, skipped"
fi

if [ "$fail" = 0 ]; then echo "swagger OK"; else echo "swagger FAILED" >&2; fi
exit $fail
