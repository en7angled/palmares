#!/usr/bin/env bash
# F1 check 11 — claim → attest → verify, driven end to end against a live preprod deployment.
#
# This is the script that asserts the registry WORKS, where scripts/smoke_interaction_api.sh
# asserts only that the write API answers and refuses correctly (it deliberately builds no
# transaction: no wallet). Here there is a wallet, so every step ends on chain and every
# assertion reads the PROJECTION — never "the request did not error". A record whose subject or
# issuer was dropped on the way in is a record nobody can resolve, and an HTTP 200 would not
# notice; so `subject`, `issuer`, `credential`, `accepted`, `deposit` and `verdict` are each read
# back out of the read surface and compared with what went in.
#
# What it leaves behind, on purpose: two profiles, one accepted attestation and one resolved
# dispute, all tagged with $ATTEST_SMOKE_TAG, so a human can open them in the API or the UI after
# the run. Nothing is cleaned up — an attestation is a permanent historical fact (the admin CLI
# has no delete-profile for the same reason).
#
# -- Signing -------------------------------------------------------------------------------------
# Every write route returns an UNSIGNED transaction and nothing else; there is no route that
# signs, and the admin CLI has no claim-profile, open-dispute or resolve-dispute command (see
# docs/deployment/attest-flow-smoke.md). So the two signatures this flow needs are supplied as
# commands, the way scripts/reconcile_koios.sh takes $PALMARES_ADMIN_CMD:
#
#   PALMARES_SIGN_CMD        reads the unsigned transaction's CBOR hex on STDIN and writes a
#                            CIP-30 shaped witness SET CBOR hex on STDOUT (the thing a wallet's
#                            `api.signTx` returns, e.g. a100818258206400…01). That is what
#                            /submit-tx's `tx_wit` parses — NOT a cardano-cli TextEnvelope, and
#                            not a bare key witness.
#   PALMARES_ADMIN_SIGN_CMD  the same contract, with the ORACLE ADMIN's key. Only the
#                            resolve-dispute transaction needs it, because the oracle validator
#                            requires that signature on chain. Defaults to $PALMARES_SIGN_CMD,
#                            which is right for the usual single-operator preprod box.
#
# Neither has a built-in default: this repo ships no signer, and a signer guessed here would be a
# wrong answer dressed as a convenience.
#
# -- Usage ---------------------------------------------------------------------------------------
#   PALMARES_INTERACTION_API   write API base URL                 (default http://localhost:8082)
#   PALMARES_QUERY_API         read API base URL                  (default http://localhost:8083)
#   BASIC_USER / BASIC_PASS    Basic auth for the write API       (required; routes are 401 without)
#   ATTEST_SMOKE_ADDR          the wallet's address, RAW CBOR HEX (required; see the note below)
#   ATTEST_SMOKE_DREP_ID       CIP-129 drep1y… of the SAME key    (required; see the note below)
#   PALMARES_SIGN_CMD          wallet signer, stdin→stdout        (required)
#   PALMARES_ADMIN_SIGN_CMD    oracle admin signer                (default $PALMARES_SIGN_CMD)
#   PALMARES_ADMIN_CMD         admin CLI, read-only here          (default "cabal run -v0 admin --")
#   ATTEST_SMOKE_TIMEOUT       seconds to wait for a confirmation
#                              or a projection                    (default 600)
#   ATTEST_SMOKE_TAG           run tag, appears in every name     (default smoke-<utc timestamp>)
#
# ATTEST_SMOKE_ADDR is the RAW HEX form, not bech32. GYAddress's FromJSON goes through
# FromHttpApiData, which is `deserialiseFromRawBytesHex` — `addr_test1…` is REFUSED. The generated
# document's own `GYAddress` description says bech32 and is wrong about it; its `format: cbor hex`,
# its 114-character length and its example are right. scripts/smoke_interaction_api.sh uses the
# hex form for the same reason.
#
# ATTEST_SMOKE_DREP_ID must be the DRep credential of the key that PALMARES_SIGN_CMD signs with.
# Claiming a key credential puts `mustBeSignedBy <that key hash>` in the transaction
# (TxBuilding/Operations.hs `claimProofSkeleton`), so an arbitrary DRep id — a golden vector, say —
# builds a transaction that cannot be signed. It is configuration for that reason, not a constant.
#
# -- Exit codes ----------------------------------------------------------------------------------
#   0  every step passed
#   1  the flow ran to the end and an ASSERTION failed — the API answered, with a wrong value
#   2  the flow could not be driven: preflight refused, a write failed, a projection never came
# The difference matters to whoever reads the nightly: 1 is a defect in the registry, 2 is a
# defect in, or an absence of, the deployment under it.
set -euo pipefail

API="${PALMARES_INTERACTION_API:-http://localhost:8082}"
QAPI="${PALMARES_QUERY_API:-http://localhost:8083}"
: "${BASIC_USER:?set BASIC_USER — every write route is 401 without credentials}"
: "${BASIC_PASS:?set BASIC_PASS — every write route is 401 without credentials}"
: "${ATTEST_SMOKE_ADDR:?set ATTEST_SMOKE_ADDR to the wallet address as RAW CBOR HEX (not bech32)}"
: "${ATTEST_SMOKE_DREP_ID:?set ATTEST_SMOKE_DREP_ID to the CIP-129 drep1y… of the signing key}"
: "${PALMARES_SIGN_CMD:?set PALMARES_SIGN_CMD — unsigned tx hex on stdin, witness set hex on stdout}"
: "${PALMARES_ADMIN_SIGN_CMD:=$PALMARES_SIGN_CMD}"
: "${PALMARES_ADMIN_CMD:=cabal run -v0 admin --}"
: "${ATTEST_SMOKE_TIMEOUT:=600}"
: "${ATTEST_SMOKE_TAG:=smoke-$(date -u +%Y%m%dT%H%M%SZ)}"

AUTH="$BASIC_USER:$BASIC_PASS"
TAG="$ATTEST_SMOKE_TAG"
fail=0
STEP=0

# Names are URL-safe on purpose — they travel as a `q=` value and as a search key — and carry the
# run tag so a re-run never matches the previous run's rows.
ISSUER_NAME="palmares-$TAG-issuer"
SUBJECT_NAME="palmares-$TAG-subject"
ATT_NAME="palmares-$TAG-attestation"
DISPUTE_NAME="palmares-$TAG-dispute"
IMG="ipfs://palmares-smoke-placeholder"

# A well-formed asset class that names nothing, for the two 404 contracts. Same shape the
# interaction-api unit tests use.
NOWHERE="00000000000000000000000000000000000000000000000000000000.6767"

# ---------------------------------------------------------------------------------------------
# Helpers. Same names and same semantics as scripts/smoke_query_api.sh — `j`/`assert` read the
# query API, because that is where every value this script checks is read back from.
# ---------------------------------------------------------------------------------------------

# 2xx only: -f makes curl fail on a 4xx so a wrong status cannot read as a wrong value.
j() { curl -fsS -H 'Accept: application/json' "$QAPI$1" | jq -c "$2"; }

# The same, unquoted and strict — for lifting an id out of a page to use in the next request.
# `-e` so an absent field is a non-zero exit and not the four characters `null`.
jr() { curl -fsS -H 'Accept: application/json' "$QAPI$1" | jq -re "$2"; }

# `|| true`: without it `set -e` aborts the run on the first failing assertion instead of
# recording it and carrying on, which is the difference between one finding and a full report.
assert() {
  got=$(j "$1" "$2" || true)
  if [ "$got" = "$3" ]; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2 => $got (want $3)"; fail=1; fi
}

# A value computed by the caller rather than fetched by `j`.
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 => $2 (want $3)"; fail=1; fi; }

# Error bodies need a NON-failing curl: -f discards the body of a 4xx, so `assert` could never
# see `.code`.
jerr() { curl -sS -H 'Accept: application/json' "$QAPI$1" | jq -c "$2"; }
assert_err() {
  got=$(jerr "$1" "$2" || true)
  if [ "$got" = "$3" ]; then echo "  ok   $1 $2"; else echo "  FAIL $1 $2 => $got (want $3)"; fail=1; fi
}

step() { STEP=$1; echo; echo "== step $1: $2"; }

# A step the flow cannot continue past. Exit 2, naming the step and what it wanted — a run that
# dies here has not found a defect in the registry, it has found that there is nothing to test.
die() { echo; echo "  FATAL step $STEP: $*" >&2; exit 2; }

# Poll until a jq filter over a query-API path equals an expected value, or the timeout expires.
#
# A bounded poll and not a fixed sleep, because the read surface is fed by attest-sync
# ASYNCHRONOUSLY: a projection does not exist the instant its transaction confirms, and neither
# /ready nor /status on either service reports attest-sync's lag at all (both speak for the
# governance index over db-sync). This loop is therefore the only check in the script that the
# projector is alive, which is why its timeout message says so.
wait_for() {
  local path="$1" filter="$2" want="$3" what="$4" deadline=$((SECONDS + ATTEST_SMOKE_TIMEOUT)) got
  while [ "$SECONDS" -lt "$deadline" ]; do
    got=$(j "$path" "$filter" 2>/dev/null || true)
    if [ "$got" = "$want" ]; then echo "  ok   $what"; return 0; fi
    sleep 5
  done
  die "$what did not appear within ${ATTEST_SMOKE_TIMEOUT}s (last: $got, want $want).
        $path $filter
        Nothing is wrong with this assertion yet: check that attest-sync is running and
        following Kupo. Neither /ready nor /status reports its lag, so this is where a dead
        projector shows up."
}

# An authenticated POST to the write API. The body of a 4xx is kept (no -f), because the refusal
# message is the only thing that says WHICH refusal fired.
post() { curl -sS -u "$AUTH" -H 'Content-Type: application/json' -d "$2" "$API$1"; }

# Build → sign → submit → confirmed. Echoes the transaction id and nothing else.
#
# The route returns a JSON string holding the unsigned CBOR hex; a refusal returns a JSON object
# or plain text instead, which is how a 4xx is told apart from a transaction here without a
# second request for the status code.
submit() {
  local route="$1" body="$2" label="$3" raw unsigned wit txid signer="${4:-$PALMARES_SIGN_CMD}"
  raw=$(post "$route" "$body") || die "$label: POST $route failed to connect"
  unsigned=$(printf '%s' "$raw" | jq -re 'strings' 2>/dev/null) ||
    die "$label: $route refused the request => $raw"

  wit=$(printf '%s' "$unsigned" | $signer) ||
    die "$label: the signer failed on the transaction $route built.
        The contract is: unsigned tx CBOR hex on stdin, CIP-30 witness SET CBOR hex on stdout."
  [ -n "$wit" ] || die "$label: the signer produced no witness"

  txid=$(jq -nc --arg t "$unsigned" --arg w "$wit" '{tx_unsigned:$t,tx_wit:$w}' |
    curl -sS -u "$AUTH" -H 'Content-Type: application/json' -d @- "$API/submit-tx" |
    jq -re 'strings' 2>/dev/null) || die "$label: /submit-tx rejected the signed transaction"

  echo >&2 "  ..   $label submitted as $txid"
  local deadline=$((SECONDS + ATTEST_SMOKE_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(curl -fsS -u "$AUTH" "$API/tx-status/$txid" | jq -c '.confirmed')" = "true" ]; then
      echo >&2 "  ok   $label confirmed"
      printf '%s' "$txid"
      return 0
    fi
    sleep 5
  done
  die "$label: $txid was not confirmed within ${ATTEST_SMOKE_TIMEOUT}s"
}

# The two wallet addresses every request body carries. CAMELCASE, deliberately: `UserAddresses`
# and `Interaction` are derived with aeson's DEFAULT options, so their wire keys are camelCase
# while every *Request type around them is snake_case. That inconsistency is a known, unfixed
# defect — spelled here the way the generated document spells it, not the way the rest of the body
# reads.
addrs() { jq -nc --arg a "$ATTEST_SMOKE_ADDR" '{usedAddresses:[$a],changeAddress:$a}'; }

# ---------------------------------------------------------------------------------------------
step 1 "preflight — both services reachable, and honest about it"
# ---------------------------------------------------------------------------------------------
probe() { curl -fsS -H 'Accept: application/json' "$1$2" | jq -c "$3"; }

[ "$(probe "$API" /health '.status' || true)" = '"healthy"' ] ||
  die "the interaction API at $API is not answering /health"
check "interaction-api identifies itself" "$(probe "$API" /health '.service' || true)" '"interaction-api"'
[ "$(probe "$QAPI" /health '.status' || true)" = '"healthy"' ] ||
  die "the query API at $QAPI is not answering /health"
check "query-api identifies itself" "$(probe "$QAPI" /health '.service' || true)" '"query-api"'

# /ready on the write API is `checkDeployedScriptsAreReady`; on the read API it is the governance
# freshness verdict. Both 503 when they are not ready, so -f turns either into a non-zero exit.
curl -fsS -o /dev/null "$API/ready" || die "the interaction API is not READY — its reference scripts do not resolve"
curl -fsS -o /dev/null "$QAPI/ready" || die "the query API is not READY — its index is behind, or the database is gone"

# The write API's /status is always 200 even when the chain reads fail, so its VALUES are the
# check and its status code is not.
ISTATUS=$(curl -fsS "$API/status")
[ "$(printf '%s' "$ISTATUS" | jq -c '.deployed_scripts')" = "true" ] ||
  die "the interaction API reports deployed_scripts=false — every write below would be a 503"
# A boolean, not null: null is the honest answer when the oracle cannot be read at all, and
# against a deployment meant to serve writes that IS the finding. true means the protocol is
# paused and every mint is refused.
PAUSED=$(printf '%s' "$ISTATUS" | jq -c '.oracle_paused')
[ "$PAUSED" = "false" ] ||
  die "the interaction API reports oracle_paused=$PAUSED (want false) — the protocol is paused, or its oracle cannot be read"
echo "  ok   /status: provider=$(printf '%s' "$ISTATUS" | jq -r '.provider') network=$(printf '%s' "$ISTATUS" | jq -r '.network')"

# The read API's /status 503s on its own when db-sync is behind, so reaching here means it is
# fresh. Its lag is printed because it is the number a stale run is diagnosed from — and because
# it is the GOVERNANCE index's lag, not attest-sync's, which nothing here reports.
QSTATUS=$(curl -fsS "$QAPI/status")
[ "$(printf '%s' "$QSTATUS" | jq -c '.governance.is_ready')" = "true" ] ||
  die "the query API reports governance.is_ready=false"
echo "  ok   /status: network=$(printf '%s' "$QSTATUS" | jq -r '.network') governance lag=$(printf '%s' "$QSTATUS" | jq -r '.governance.lag_seconds')s"
echo "  ..   neither service reports attest-sync's lag; the polls below are what catch a dead projector"

# ---------------------------------------------------------------------------------------------
step 2 "two profiles — an auditor that issues, and a DRep that claims a credential"
# ---------------------------------------------------------------------------------------------
# The issuer claims nothing: an Auditor corresponds to no on-chain credential, and the read layer
# must present it as unclaimed rather than as verified.
ISSUER_TX=$(submit /claim-profile "$(jq -nc \
  --arg n "$ISSUER_NAME" --arg d "issuer profile for $TAG" --arg i "$IMG" \
  --argjson ua "$(addrs)" \
  '{kind:"auditor",name:$n,description:$d,image_uri:$i,user_addresses:$ua}')" "issuer profile")

# The subject claims the DRep credential, with a key witness. This claim is the thing the word
# "verified" rests on — hence `witness: {"tag":"key"}` and the proof-of-control the minting policy
# requires, rather than a credential string written into a datum by anyone who asks.
SUBJECT_TX=$(submit /claim-profile "$(jq -nc \
  --arg n "$SUBJECT_NAME" --arg d "subject profile for $TAG" --arg i "$IMG" \
  --arg c "$ATTEST_SMOKE_DREP_ID" --argjson ua "$(addrs)" \
  '{kind:"person_d_rep",name:$n,description:$d,image_uri:$i,
    credential:$c,witness:{tag:"key"},user_addresses:$ua}')" "subject profile")

wait_for "/profiles?q=$ISSUER_NAME" '.total' '1' "the issuer profile is projected"
wait_for "/profiles?q=$SUBJECT_NAME" '.total' '1' "the subject profile is projected"
ISSUER=$(jr "/profiles?q=$ISSUER_NAME" '.items[0].id') || die "the issuer projection carries no id"
SUBJECT=$(jr "/profiles?q=$SUBJECT_NAME" '.items[0].id') || die "the subject projection carries no id"
echo "  ..   issuer=$ISSUER"
echo "  ..   subject=$SUBJECT"

# What went in came back out. The datum fields, not the status code.
assert "/profiles/$ISSUER" '[.name,.kind,.credential]' "[\"$ISSUER_NAME\",\"auditor\",null]"
assert "/profiles/$ISSUER" '[.description,.image_uri]' "[\"issuer profile for $TAG\",\"$IMG\"]"
assert "/profiles/$ISSUER" '.slot > 0 and (.block_hash|test("^[0-9a-f]{64}$"))' 'true'
assert "/profiles/$SUBJECT" '[.name,.kind]' "[\"$SUBJECT_NAME\",\"person_d_rep\"]"
# The credential is stored in its canonical CIP-129 rendering, which is not necessarily the
# spelling the operator typed — so the assertion is that one is there and that its header byte
# decodes to a KEY credential. Whether it is the same credential is settled in step 5, by the
# lookup route, which canonicalises server-side instead of making this script do bech32 in bash.
assert "/profiles/$SUBJECT" '[.credential != null, .credential_is_script]' '[true,false]'

# ---------------------------------------------------------------------------------------------
step 3 "one attestation, issued by the issuer about the subject, PENDING"
# ---------------------------------------------------------------------------------------------
# claimed_period is fixed rather than derived from the clock: it is SELF-REPORTED, never
# chain-verified, and only its ordering is checked — so there is nothing for a date computation to
# be right about, and `date -d` is not portable anyway.
ISSUE_TX=$(submit /issue-attestation "$(jq -nc \
  --arg s "$SUBJECT" --arg b "$ISSUER" --arg n "$ATT_NAME" \
  --arg d "attestation for $TAG" --arg i "$IMG" --arg t "$TAG" --argjson ua "$(addrs)" \
  '{subject_profile_id:$s,issuer_profile_id:$b,kind:"role_held",
    name:$n,description:$d,image_uri:$i,
    other_metadata:[["smoke_run",$t]],
    claimed_period:["2025-01-01T00:00:00Z","2025-12-31T00:00:00Z"],
    user_addresses:$ua}')" "attestation")

wait_for "/attestations?subject=$SUBJECT&issuer=$ISSUER" '.total' '1' "the attestation is projected"
ATT=$(jr "/attestations?subject=$SUBJECT&issuer=$ISSUER" '.items[0].id') || die "the attestation projection carries no id"
echo "  ..   attestation=$ATT"

# PENDING, and attributed to the right two profiles. The subject/issuer pair is asserted even
# though the query above filtered on it: the filter proves the COLUMNS match, this proves the
# row publishes them, and a projection that silently swapped them would satisfy neither.
assert "/attestations/$ATT" '.attestation.accepted' 'false'
assert "/attestations/$ATT" '[.attestation.subject,.attestation.issuer]' "[\"$SUBJECT\",\"$ISSUER\"]"
assert "/attestations/$ATT" '[.attestation.kind,.attestation.name]' "[\"role_held\",\"$ATT_NAME\"]"
assert "/attestations/$ATT" '.attestation.other_metadata' "[[\"smoke_run\",\"$TAG\"]]"
# Both bounds or neither: a period with one bound is not a period.
assert "/attestations/$ATT" '.attestation.claimed_period|length' '2'
# tx-proof: the row names the output it was projected from.
assert "/attestations/$ATT" '.attestation.tx_hash' "\"$ISSUE_TX\""
assert "/attestations/$ATT" '.attestation.output_index >= 0' 'true'
# `accepted` has no default, so the unfiltered list carries unacknowledged claims and the filter
# is what separates them.
assert "/attestations?subject=$SUBJECT&accepted=false" "[.items[].id]|index(\"$ATT\") != null" 'true'
assert "/attestations?subject=$SUBJECT&accepted=true" '.total' '0'

# ---------------------------------------------------------------------------------------------
step 4 "acceptance by the subject, ACCEPTED"
# ---------------------------------------------------------------------------------------------
ACCEPT_TX=$(submit /accept-attestation "$(jq -nc \
  --arg a "$ATT" --argjson ua "$(addrs)" \
  '{attestation_id:$a,user_addresses:$ua}')" "acceptance")

wait_for "/attestations/$ATT" '.attestation.accepted' 'true' "the attestation reads as accepted"
# The projection is upserted by attestation id from whichever output currently holds it, so
# acceptance moves the tx-proof to the accepting transaction. Asserted, not assumed: if it still
# named the issuing transaction, the row would be pointing at a UTxO that no longer exists.
assert "/attestations/$ATT" '.attestation.tx_hash' "\"$ACCEPT_TX\""
assert "/attestations?subject=$SUBJECT&accepted=true" '.total' '1'
assert "/attestations?subject=$SUBJECT&accepted=false" '.total' '0'
assert "/attestations/$ATT" '.disputes' '[]'

# ---------------------------------------------------------------------------------------------
step 5 "verification through the READ surface — the point of the whole script"
# ---------------------------------------------------------------------------------------------
# The list route, not just the detail route: a profile that resolves by id and never appears in
# the registry is a profile nobody can find. Default ordering is registered_at descending, so the
# two rows this run created are at the front of the first page.
assert /profiles "[.items[].id]|index(\"$SUBJECT\") != null" 'true'
assert /profiles "[.items[].id]|index(\"$ISSUER\") != null" 'true'

# The verify direction. `total` is the answer to "is this contested" — 1 is a single claim, more
# than one means several profiles claim the same credential and the API picks no winner, which a
# re-run against the same key legitimately produces. So: our profile is among the claimants, and
# the credential decodes as a key credential.
assert "/profiles/by-credential/$ATTEST_SMOKE_DREP_ID" '.total >= 1' 'true'
assert "/profiles/by-credential/$ATTEST_SMOKE_DREP_ID" "[.items[].id]|index(\"$SUBJECT\") != null" 'true'
assert "/profiles/by-credential/$ATTEST_SMOKE_DREP_ID" '.items[0].credential_is_script' 'false'

# CIP-129 ONLY, and the two refusals are the contract rather than an accident: neither a CIP-105
# id nor 56 bare hex characters carries a header byte, and `drep` is the HRP for both credential
# kinds, so neither can say key or script. Answering "nobody claims it" would be a false negative
# dressed as a result. These three spellings are the SAME 28 bytes — the golden vectors from
# src/test/UnitTests/GovIds.hs — so the refusal is about the FORM and not about the credential.
assert_err /profiles/by-credential/drep1symc604gnd50plqfj393lyljl6u9zvv0r9he3wjq98v2sz3vtkp \
  '.code' '"invalid_drep_id"'
assert_err /profiles/by-credential/81378d3ea89b68f0fc09944b1f93f2feb851318f196f98ba4029d8a8 \
  '.code' '"invalid_drep_id"'
# And the accepted script form of those same bytes is NOT refused — it resolves to an empty page,
# which is the difference between "cannot answer" and "no claim".
assert /profiles/by-credential/drep1ywqn0rf74zdk3u8upx2yk8un7tlts5f33uvklx96gq5a32qmuzqx0 '.total' '0'

# The track record: what others say about this profile, accepted first.
assert "/profiles/$SUBJECT/attestations" '.total' '1'
assert "/profiles/$SUBJECT/attestations" '[.items[0].id,.items[0].accepted]' "[\"$ATT\",true]"
# 404 and not an empty page: "no rows" for a mistyped id reads as "this profile has no record".
assert_err "/profiles/$NOWHERE/attestations" '.code' '"profile_not_found"'
assert_err "/profiles/$NOWHERE" '.code' '"profile_not_found"'
assert_err "/attestations/$NOWHERE" '.code' '"attestation_not_found"'

# ---------------------------------------------------------------------------------------------
step 6 "one dispute, opened and then resolved by the oracle admin"
# ---------------------------------------------------------------------------------------------
# What the deposit SHOULD be, from the oracle itself, so the projected number is compared with
# the protocol's own parameter rather than with "some positive integer". Read-only; the admin CLI
# has no resolve-dispute command, which is why the resolution below goes over HTTP.
DEPOSIT=$(${PALMARES_ADMIN_CMD} query-oracle 2>/dev/null |
  sed -n 's/.*Dispute Deposit: *\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$DEPOSIT" ] ||
  die "could not read the dispute deposit from '\$PALMARES_ADMIN_CMD query-oracle'"
echo "  ..   the oracle requires a deposit of $DEPOSIT lovelace"

# deposit_to is where the deposit returns on EITHER verdict, and Md8 requires it to be an address
# the opening transaction spends from — so it is this wallet's own address and not a placeholder.
# An address no real output can carry makes resolution unsatisfiable and leaves the dispute open
# against its target forever.
OPEN_TX=$(submit /open-dispute "$(jq -nc \
  --arg a "$ATT" --arg o "$ISSUER" --arg n "$DISPUTE_NAME" \
  --arg d "dispute for $TAG" --arg i "$IMG" --arg addr "$ATTEST_SMOKE_ADDR" --argjson ua "$(addrs)" \
  '{attestation_id:$a,opened_by_profile_id:$o,name:$n,description:$d,image_uri:$i,
    deposit_to:$addr,user_addresses:$ua}')" "dispute")

wait_for "/disputes?target=$ATT" '.total' '1' "the dispute is projected"
DISPUTE=$(jr "/disputes?target=$ATT" '.items[0].id') || die "the dispute projection carries no id"
echo "  ..   dispute=$DISPUTE"

# Open: `verdict` is null while it is, and `resolved` is the presence of a verdict rather than a
# verdict value.
assert "/disputes?target=$ATT" '.items[0].verdict' 'null'
assert "/disputes?target=$ATT" "[.items[0].target,.items[0].opened_by]" "[\"$ATT\",\"$ISSUER\"]"
assert "/disputes?target=$ATT" '.items[0].deposit' "$DEPOSIT"
assert "/disputes?target=$ATT&resolved=false" '.total' '1'
assert "/disputes?target=$ATT&resolved=true" '.total' '0'
# Inlined on the detail route, and the attestation is STILL there: a dispute is published beside
# what it contests and never hides it, so a non-empty `disputes` array is the whole signal.
assert "/attestations/$ATT" "[.disputes[].id]|index(\"$DISPUTE\") != null" 'true'
assert "/attestations/$ATT" '.attestation.accepted' 'true'

# The resolution. Built over HTTP and signed by the ORACLE ADMIN — the oracle validator requires
# that signature on chain, which is why this one route accepts an action no AdminActionType
# constructor is allowed to carry: the unsigned transaction is the product.
RESOLVE_TX=$(submit /resolve-dispute "$(jq -nc \
  --arg d "$DISPUTE" --argjson ua "$(addrs)" \
  '{dispute_id:$d,verdict:"upheld",user_addresses:$ua}')" "resolution" "$PALMARES_ADMIN_SIGN_CMD")

wait_for "/disputes?target=$ATT" '.items[0].verdict' '"upheld"' "the dispute reads as upheld"
assert "/disputes?target=$ATT&resolved=true" '.total' '1'
assert "/disputes?target=$ATT&resolved=false" '.total' '0'
assert /disputes "[.items[].id]|index(\"$DISPUTE\") != null" 'true'
assert "/attestations/$ATT" '.disputes[0].verdict' '"upheld"'
# An upheld dispute does not delete or hide the attestation, and does not un-accept it.
assert "/attestations/$ATT" '.attestation.accepted' 'true'
assert "/profiles/$SUBJECT/attestations" '.total' '1'

# ---------------------------------------------------------------------------------------------
echo
echo "the chain, for the record:"
echo "  issuer profile      $ISSUER_TX"
echo "  subject profile     $SUBJECT_TX"
echo "  attestation issued  $ISSUE_TX"
echo "  attestation accepted $ACCEPT_TX"
echo "  dispute opened      $OPEN_TX"
echo "  dispute resolved    $RESOLVE_TX"
echo
echo "left on chain for inspection, tagged $TAG:"
echo "  $QAPI/profiles/$SUBJECT"
echo "  $QAPI/profiles/$SUBJECT/attestations"
echo "  $QAPI/attestations/$ATT"
echo "  $QAPI/profiles/by-credential/$ATTEST_SMOKE_DREP_ID"
echo
if [ "$fail" = 0 ]; then echo "smoke OK — all six steps passed"; else echo "FAILURES above"; exit 1; fi
