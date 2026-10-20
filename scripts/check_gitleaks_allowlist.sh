#!/usr/bin/env bash
# The allowlist in .gitleaks.toml is not a hole, and this is what says so.
#
# That file turns OFF one rule — `generic-api-key` — on `test/fixtures/koios/*.json`, because the
# Koios recordings carry on-chain credential hashes in proposal metadata and that rule cannot tell
# a public key hash from a secret. The risk of any allowlist is that it quietly stops catching the
# thing it was never meant to excuse. So this plants a real-looking credential in exactly that
# path and asserts the gate still fails, then plants a high-entropy hash under a field named
# `keyHash` and asserts it does not. Both halves matter: a gate that catches nothing and a gate
# that catches everything are equally useless.
#
# Nothing it writes is a real credential: the AWS key id is the one from gitleaks' own test
# corpus, and the private key is a BEGIN marker with eight bytes of nothing after it.
#
# A `ghp_…` GitHub token would be the other obvious plant, and it is deliberately NOT here.
# GitHub's own push protection scans file content and rejected the push that contained one as a
# literal — correctly: a valid-looking token in a committed file is indistinguishable from a
# leaked one. Two rules from two different families prove the same point without arguing with a
# gate that is on our side.
#
# IT SCANS A COPY, at the same relative path, in a temporary root. Two reasons, and the first is
# why the obvious version of this script does not work: gitleaks reports a path relative to the
# SCAN TARGET, so `gitleaks dir test/fixtures/koios` reports `proposal_list.json` and the
# allowlist's `test/fixtures/koios/.*\.json` never matches. Scanning the repository root instead
# would walk dist-newstyle — measured, 969 MB and 1,984 findings in build artefacts. A copy keeps
# the relative path the config is written against and nothing else.
#
# Usage: scripts/check_gitleaks_allowlist.sh [path-to-gitleaks]
set -euo pipefail

GITLEAKS="${1:-$(command -v gitleaks || true)}"
if [ -z "$GITLEAKS" ] || [ ! -x "$GITLEAKS" ]; then
  echo "  skip gitleaks not found (pass its path as \$1, or install it)"
  exit 0
fi

REL=test/fixtures/koios
ROOT=$(mktemp -d)
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

mkdir -p "$ROOT/$REL"
cp .gitleaks.toml "$ROOT/.gitleaks.toml"
cp "$REL"/*.json "$ROOT/$REL/"

PLANTED="$ROOT/$REL/zz-planted-secret.json"
DECOY="$ROOT/$REL/zz-planted-hash.json"
fail=0

# Run from the copied root so the reported paths are the ones the config is written against.
scan() { (cd "$ROOT" && "$GITLEAKS" dir --no-banner --redact --exit-code 1 . >/dev/null 2>&1); }

echo "== the gitleaks allowlist is rule-scoped, not path-scoped"

# 0. Baseline: the recordings themselves must pass, or the rest proves nothing.
if scan; then
  echo "  ok   the recorded fixtures alone are clean"
else
  echo "  FAIL the recorded fixtures alone already trip the gate"
  fail=1
fi

# 1. A credential a DIFFERENT rule owns must still be caught inside the allowlisted path.
cat > "$PLANTED" <<'EOF'
{ "note": "planted by scripts/check_gitleaks_allowlist.sh",
  "aws_access_key_id": "AKIALALEMEL33243OLIB",
  "key": "-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJB\n-----END RSA PRIVATE KEY-----" }
EOF
if scan; then
  echo "  FAIL a planted AWS key and private key in $REL did NOT trip the gate"
  fail=1
else
  echo "  ok   a planted AWS key and private key in $REL still trip the gate"
fi
rm -f "$PLANTED"

# 2. ...and the thing the allowlist exists for must NOT be caught: an on-chain credential hash
#    under a field name containing "key", which is the exact shape proposal metadata carries.
cat > "$DECOY" <<'EOF'
{ "proposal_description": { "tag": "NewCommittee",
    "contents": [ { "keyHash": "863ae82daba6a0044c651216e4989b45044b07296533e6a3daf338cd" } ] } }
EOF
if scan; then
  echo "  ok   an on-chain keyHash in $REL does not trip the gate"
else
  echo "  FAIL an on-chain keyHash in $REL trips the gate, so the allowlist is not working"
  fail=1
fi
rm -f "$DECOY"

if [ "$fail" = 0 ]; then echo "allowlist OK"; else echo "allowlist FAILED" >&2; fi
exit $fail
