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
# What it leaves behind, on purpose: two profiles, three attestations (one accepted, two anchored by
# step 7) and one resolved dispute, all tagged with $ATTEST_SMOKE_TAG, so a human can open them in
# the API or the UI after
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
#   ATTEST_SMOKE_DREP_ID       CIP-129 drep1y… of the SAME key    (required; `operator-address`
#                                                                 prints it — see the note below)
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
# WHERE BOTH VALUES COME FROM: `$PALMARES_ADMIN_CMD operator-address` prints the address in raw hex
# and the CIP-129 DRep id of the same key, from one derivation. Taking them from there is what keeps
# them naming the same key; assembling the DRep id by slicing the hash out of the address hex is
# deriving it with a second tool, and a mismatch would surface as a node rejection at step 2.
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

# Checked here rather than left to the 400 at step 2, because step 2 is two minted profiles later.
#
# LENGTH is the discriminator, not the `drep1y` prefix. A prefix check was the first thing written
# here and it is wrong about 1 id in 32: the header byte's top five bits are what bech32's first
# character encodes, and they are `00100` for ANY first byte in 0x20..0x27 — so a CIP-105 id whose
# hash happens to start in that range also renders as `drep1y`. The byte count cannot collide:
# CIP-129 carries 29 bytes and bech32s to 58 characters, CIP-105 carries 28 and gives 56, and a bare
# 28-byte hex hash is 56 characters too. Verified against all three vectors in UnitTests.WritePath.
#
# The prefix is still required, because 58 characters of anything else is not an id either. Neither
# check distinguishes a key credential from a script one (0x22 and 0x23 share those five bits), and
# neither needs to: `parseClaimCredential` reads the whole byte and the registry branches on it.
case "$ATTEST_SMOKE_DREP_ID" in
  drep1*) [ ${#ATTEST_SMOKE_DREP_ID} -eq 58 ] ||
    die "ATTEST_SMOKE_DREP_ID is ${#ATTEST_SMOKE_DREP_ID} characters; a CIP-129 drep id is 58. \
A 56-character value is CIP-105 or a bare hex hash — neither carries the header byte that says key \
or script, so parseClaimCredential refuses it. Run '$PALMARES_ADMIN_CMD operator-address'" ;;
  *) die "ATTEST_SMOKE_DREP_ID=$ATTEST_SMOKE_DREP_ID does not start with drep1 — \
run '$PALMARES_ADMIN_CMD operator-address' and use the DRep id it prints" ;;
esac

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
# fresh. Its lag is printed because it is the number a stale run is diagnosed from — and it is the
# GOVERNANCE index's lag specifically, which is why attest-sync's is read separately just below.
QSTATUS=$(curl -fsS "$QAPI/status")
[ "$(printf '%s' "$QSTATUS" | jq -c '.governance.is_ready')" = "true" ] ||
  die "the query API reports governance.is_ready=false"
echo "  ok   /status: network=$(printf '%s' "$QSTATUS" | jq -r '.network') governance lag=$(printf '%s' "$QSTATUS" | jq -r '.governance.lag_seconds')s"

# THE SECOND INDEXER, and the one every assertion after step 2 depends on. `governance.lag_seconds`
# above is db-sync's; this is attest-sync's, from `palmares_attest.chain_cursor`. Without it this
# script found a dead projector by waiting ATTEST_SMOKE_TIMEOUT seconds for a projection that was
# never coming, and then reported a timeout — exit 2 for "could not be driven", which is correct but
# arrives ten minutes late and does not say which indexer was at fault.
#
# `null` is fatal HERE and not elsewhere, because it means "no evidence of a projector" and this
# flow reads nothing but projections — while /ready passes it, correctly, since a governance-only
# deployment runs no projector and is not broken.
#
# THE MESSAGE NAMES THREE CAUSES BECAUSE THERE ARE THREE. The first draft of this said "attest-sync
# has never run", which is one of them and was asserted as the only one — and `attestCursorSlot`'s
# own Haddock says it collapses two states on purpose, while the poll adds a third. Blaming
# attest-sync for a missing GRANT sends whoever reads the nightly to the wrong service, and the
# third cause clears by itself, so the message has to say "retry" rather than "it is dead".
ATTEST_LAG=$(printf '%s' "$QSTATUS" | jq -r '.attest_lag_seconds')
case "$ATTEST_LAG" in
  null | "")
    die "the query API reports attest_lag_seconds=null — no projector cursor is VISIBLE, which is \
three things and not one: attest-sync has never run against this database; or query-api's role \
cannot SELECT palmares_attest.chain_cursor, which reads as absence because information_schema.tables \
shows only what the role may see — run scripts/check_roles.sh, which asserts the pair of default \
privileges that makes the order of apply-roles and attest-sync's first boot stop mattering; \
or the first poll since boot raised, which clears on the next one — retry before blaming anything. \
Either way this flow reads nothing but projections, so every wait below would time out" ;;
  *) echo "  ok   /status: attest-sync trails db-sync's cursor by ${ATTEST_LAG}s (add governance lag for absolute staleness)" ;;
esac

# ---------------------------------------------------------------------------------------------
step 2 "two profiles — an auditor that issues, and a DRep that claims a credential"
# ---------------------------------------------------------------------------------------------
# The issuer claims nothing: an Auditor corresponds to no on-chain credential, and the read layer
# must present it as unclaimed rather than as verified.
ISSUER_TX=$(submit /claim-profile "$(jq -nc \
  --arg n "$ISSUER_NAME" --arg d "issuer profile for $TAG" --arg i "$IMG" \
  --argjson ua "$(addrs)" \
  '{kind:"auditor",name:$n,description:$d,image_uri:$i,user_addresses:$ua}')" "issuer profile")

# The subject's profile. No credential here: ADR 0003 made a binding its own record, so minting a
# profile claims nothing and this request has no `credential` and no `witness` field at all. The
# claim is the next step, and it is a second transaction on purpose.
SUBJECT_TX=$(submit /claim-profile "$(jq -nc \
  --arg n "$SUBJECT_NAME" --arg d "subject profile for $TAG" --arg i "$IMG" \
  --argjson ua "$(addrs)" \
  '{kind:"person_d_rep",name:$n,description:$d,image_uri:$i,user_addresses:$ua}')" "subject profile")

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
# Nothing is bound yet, and asserting that BEFORE the claim is the point: the profile column is
# derived, so `null` here and a value after the next step is the derivation actually running.
assert "/profiles/$SUBJECT" '.credential' 'null'

# The binding, as its own transaction and its own record (ADR 0003). `witness: {"tag":"key"}` is how
# the input that proves control of the credential is spent, and `Mc3` is the rule that demands it —
# the same proof the old `Mp3` demanded, now attached to a transaction whose whole visible purpose
# is the binding instead of to a profile mint that could be about anything.
submit /claim-credential "$(jq -nc \
  --arg p "$SUBJECT" --arg c "$ATTEST_SMOKE_DREP_ID" \
  --arg n "credential claim for $TAG" --arg i "$IMG" --argjson ua "$(addrs)" \
  '{profile_id:$p,credential:$c,witness:{tag:"key"},
    name:$n,description:"binds the subject profile to its DRep credential",image_uri:$i,
    user_addresses:$ua}')" "credential claim" >/dev/null

# The credential is stored in its canonical CIP-129 rendering, which is not necessarily the
# spelling the operator typed — so the assertion is that one is there and that its header byte
# decodes to a KEY credential. Whether it is the same credential is settled in step 5, by the
# lookup route, which canonicalises server-side instead of making this script do bech32 in bash.
wait_for "/profiles/$SUBJECT" '.credential != null' 'true' "the claim is projected onto the profile"
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
# ONE pending record left, not none: the credential claim from step 2 is an attestation about this
# same subject and it is never accepted. It does not need to be — `Mc1` makes a claim self-issued,
# so the subject's consent is already in the mint, and acceptance by the issuer-who-is-the-subject
# would add nothing. The derivation that publishes the credential does not look at `accepted`.
assert "/attestations?subject=$SUBJECT&accepted=false" '.total' '1'
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

# The track record: what others say about this profile, accepted first. TWO records, because ADR
# 0003 put the credential claim in this same list — a binding is part of the track record, and the
# list is where a reader sees it. Asserted by id rather than by position so the ordering rule is
# not what this case is about.
assert "/profiles/$SUBJECT/attestations" '.total' '2'
assert "/profiles/$SUBJECT/attestations" "[.items[]|select(.id==\"$ATT\")|.accepted]" '[true]'
assert "/profiles/$SUBJECT/attestations" '[.items[]|select(.kind=="credential_claim")]|length' '1'
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
assert "/profiles/$SUBJECT/attestations" '.total' '2'

# ---------------------------------------------------------------------------------------------
step 7 "the level-1 anchor — money linked to delivery, and a pointer that resolves to nothing"
# ---------------------------------------------------------------------------------------------
# F1 check 11's remaining half: "with and without a treasury anchor … the anchored attestation shows
# the corresponding treasury withdrawal from palmares.treasury_withdrawal in the API, and one with an
# unresolvable anchor is marked as such rather than hidden."
#
# ADR 0008: the anchor is two reserved `other_metadata` keys, not a datum field, because the
# specification itself decided the anchor is unvalidated on chain — so a typed field would carry the
# same zero guarantee at the price of a new registry. The consequence this step exists to prove is
# that resolution happens at READ time and the API says which of three things happened.
#
# The resolvable pair is read out of the live index rather than hard-coded: a pinned
# (gov_action_id, stake_address) would rot the first time preprod is re-synced from a later snapshot.
WD=$(curl -fsS -H 'Accept: application/json' "$QAPI/treasury-withdrawals?limit=1" | jq -c '.items[0] // empty') || true
if [ -z "$WD" ]; then
  echo "  --   no treasury withdrawal in the index, anchor resolution not asserted"
else
  WD_ACTION=$(echo "$WD" | jq -re '.gov_action_id')
  WD_ADDR=$(echo "$WD" | jq -re '.stake_address')
  echo "  ..   anchoring to $WD_ACTION / $WD_ADDR"

  # (a) WITH a resolvable anchor.
  ANCHORED_NAME="$TAG-anchored"
  ANCHORED_TX=$(submit /issue-attestation "$(jq -nc \
    --arg s "$SUBJECT" --arg b "$ISSUER" --arg n "$ANCHORED_NAME" \
    --arg d "anchored attestation for $TAG" --arg i "$IMG" --arg t "$TAG" \
    --arg ga "$WD_ACTION" --arg sa "$WD_ADDR" --argjson ua "$(addrs)" \
    '{subject_profile_id:$s,issuer_profile_id:$b,kind:"milestone_delivered",
      name:$n,description:$d,image_uri:$i,
      other_metadata:[["smoke_run",$t],
                      ["palmares:level1_gov_action",$ga],
                      ["palmares:level1_stake_address",$sa]],
      user_addresses:$ua}')" "anchored attestation")

  wait_for "/attestations?subject=$SUBJECT&issuer=$ISSUER&kind=milestone_delivered" '.total' '1' \
    "the anchored attestation is projected"
  ANCHORED=$(jr "/attestations?subject=$SUBJECT&issuer=$ISSUER&kind=milestone_delivered" '.items[0].id') \
    || die "the anchored attestation projection carries no id"
  echo "  ..   anchored=$ANCHORED  tx=$ANCHORED_TX"

  # The pointer resolved, and the API publishes the withdrawal it names. `amount` is asserted
  # present and positive rather than against a literal: it is a chain fact and pinning it would
  # make this script fail when preprod moves.
  assert "/attestations/$ANCHORED" '.level1_anchor.status' '"resolved"'
  assert "/attestations/$ANCHORED" '.level1_anchor.gov_action_id' "\"$WD_ACTION\""
  assert "/attestations/$ANCHORED" '.level1_anchor.stake_address' "\"$WD_ADDR\""
  assert "/attestations/$ANCHORED" '.level1_anchor.withdrawal != null' 'true'
  assert "/attestations/$ANCHORED" '.level1_anchor.withdrawal.amount > 0' 'true'
  # The two keys stay in `other_metadata` as well, because removing them would make the API
  # disagree with the datum. A client rendering raw metadata filters them.
  assert "/attestations/$ANCHORED" \
    '[.attestation.other_metadata[]|select(.[0]=="palmares:level1_gov_action")]|length' '1'

  # (b) WITHOUT an anchor — the attestation from step 3, which must read `null` and not an empty
  # object. Most attestations are unanchored: a vendor paid out of an organization's budget has no
  # on-chain payment fact and belongs in the registry anyway (spec §2).
  assert "/attestations/$ATT" '.level1_anchor' 'null'

  # (c) WITH an anchor that resolves to NOTHING, built by CROSSING two real withdrawals: action from
  # one, paid address from another. Both halves are well-formed, so the write API accepts it — the
  # pair simply names a payment nobody made.
  #
  # Crossed rather than corrupted, because corrupting a bech32 id breaks its checksum and the write
  # API would refuse it as MALFORMED, which is case (d) and a different assertion. There is no way to
  # mint a valid-but-nonexistent bech32 id from shell, and this case is the better test anyway: it is
  # the mistake a real client makes, pasting the right action beside the wrong address.
  #
  # It must read `unresolved`, never hidden: the datum permanently says this attestation is about
  # that payment, so publishing it as unanchored would be a different claim about a record nobody
  # can change.
  WD2=$(curl -fsS -H 'Accept: application/json' "$QAPI/treasury-withdrawals?limit=2" \
    | jq -c '[.items[]|select(.stake_address != "'"$WD_ADDR"'")][0] // empty') || true
  if [ -z "$WD2" ]; then
    echo "  --   only one distinct withdrawal address in the index, `unresolved` not asserted live"
  else
    OTHER_ADDR=$(echo "$WD2" | jq -re '.stake_address')
    UNRES_TX=$(submit /issue-attestation "$(jq -nc \
      --arg s "$SUBJECT" --arg b "$ISSUER" --arg n "$TAG-unresolvable" \
      --arg d "unresolvable anchor for $TAG" --arg i "$IMG" --arg t "$TAG" \
      --arg ga "$WD_ACTION" --arg sa "$OTHER_ADDR" --argjson ua "$(addrs)" \
      '{subject_profile_id:$s,issuer_profile_id:$b,kind:"audit_passed",
        name:$n,description:$d,image_uri:$i,
        other_metadata:[["smoke_run",$t],
                        ["palmares:level1_gov_action",$ga],
                        ["palmares:level1_stake_address",$sa]],
        user_addresses:$ua}')" "unresolvable-anchor attestation")
    wait_for "/attestations?subject=$SUBJECT&issuer=$ISSUER&kind=audit_passed" '.total' '1' \
      "the unresolvable-anchor attestation is projected"
    UNRES=$(jr "/attestations?subject=$SUBJECT&issuer=$ISSUER&kind=audit_passed" '.items[0].id') \
      || die "the unresolvable-anchor projection carries no id"
    # The ACTION exists here and the PAIR does not, which is exactly the case that must not read
    # `resolved`: "resolved" means what the client asked resolved, not that something did.
    assert "/attestations/$UNRES" '.level1_anchor.status' '"unresolved"'
    assert "/attestations/$UNRES" '.level1_anchor.withdrawal' 'null'
    assert "/attestations/$UNRES" '.level1_anchor.gov_action_id' "\"$WD_ACTION\""
    assert "/attestations/$UNRES" '.level1_anchor.stake_address' "\"$OTHER_ADDR\""
  fi

  # (d) A MALFORMED anchor never reaches the chain: the write API refuses it before a signature.
  # This is the half that cannot be asserted from a projection, because there is nothing to project.
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$BASIC_USER:$BASIC_PASS" \
    -H 'Content-Type: application/json' -X POST "$IAPI/issue-attestation" \
    -d "$(jq -nc --arg s "$SUBJECT" --arg b "$ISSUER" --arg i "$IMG" --argjson ua "$(addrs)" \
      '{subject_profile_id:$s,issuer_profile_id:$b,kind:"endorsement",
        name:"malformed-anchor",description:"not a gov action id",image_uri:$i,
        other_metadata:[["palmares:level1_gov_action","gov_action1nope"]],
        user_addresses:$ua}')")
  if [ "$code" = 400 ]; then echo "  ok   a malformed anchor is refused before a signature (400)"
  else echo "  FAIL a malformed anchor should be a 400, got $code"; fail=1; fi
  # An address with no action is not half an anchor: the withdrawal table is keyed by the PAIR.
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$BASIC_USER:$BASIC_PASS" \
    -H 'Content-Type: application/json' -X POST "$IAPI/issue-attestation" \
    -d "$(jq -nc --arg s "$SUBJECT" --arg b "$ISSUER" --arg i "$IMG" --arg sa "$WD_ADDR" --argjson ua "$(addrs)" \
      '{subject_profile_id:$s,issuer_profile_id:$b,kind:"endorsement",
        name:"half-anchor",description:"an address with no action",image_uri:$i,
        other_metadata:[["palmares:level1_stake_address",$sa]],
        user_addresses:$ua}')")
  if [ "$code" = 400 ]; then echo "  ok   an address with no action is refused (400)"
  else echo "  FAIL an address with no action should be a 400, got $code"; fail=1; fi
fi

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
if [ "$fail" = 0 ]; then echo "smoke OK — all seven steps passed"; else echo "FAILURES above"; exit 1; fi
