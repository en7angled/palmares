#!/usr/bin/env bash
# The allowlist in .gitleaks.toml is not a hole, and this is what says so.
#
# That file turns OFF one rule — `generic-api-key` — in four narrow places, because that rule
# cannot tell a public credential hash from a secret. The risk of any allowlist is that it quietly
# stops catching the thing it was never meant to excuse, so each narrowing is tested from both
# sides: a real-looking credential in the same place must still fail the gate, and the public value
# the narrowing exists for must not. Both halves matter: a gate that catches nothing and a gate that
# catches everything are equally useless.
#
# Three of the four are covered here — the Koios wire fixtures (by path), bech32 governance
# identifiers and raw 28-byte credential hashes (both by value shape, any path). The fourth,
# `cabal.project`'s CHaP root keys, is a single published constant in a file no test writes to.
#
# Nothing it writes is a real credential: the AWS key id is the one from gitleaks' own test
# corpus, and the private key is a BEGIN marker with eight bytes of nothing after it.
#
# EVERY PLANT IS ASSEMBLED FROM FRAGMENTS, and that is not obfuscation. This file is committed, so
# gitleaks scans IT — and a literal plant in here is a finding like any other. Measured: the first
# version of this script put 2 findings in the repository's own history, its AWS key id and its
# `keyHash` decoy. Split across a shell concatenation, no pattern matches the file while the JSON
# it writes still carries the whole value.
#
# A `ghp_…` GitHub token would be the other obvious plant, and it is deliberately NOT here even in
# fragments: GitHub's own push protection scans file content and rejected the push that contained
# one as a literal — correctly, a valid-looking token in a committed file is indistinguishable from
# a leaked one. An AWS key id and a private-key block make the same point from two rule families
# without arguing with a gate that is on our side.
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
# Assembled, never written out: see the header.
AWS="AKIA""LALEMEL33243OLIB"
PK_BEGIN="-----BEGIN"" RSA PRIVATE KEY-----"
printf '{ "note": "planted by scripts/check_gitleaks_allowlist.sh",\n  "aws_access_key_id": "%s",\n  "key": "%s\\nMIIBOgIBAAJB" }\n' \
  "$AWS" "$PK_BEGIN" > "$PLANTED"
if scan; then
  echo "  FAIL a planted AWS key and private key in $REL did NOT trip the gate"
  fail=1
else
  echo "  ok   a planted AWS key and private key in $REL still trip the gate"
fi
rm -f "$PLANTED"

# 2. ...and the thing the allowlist exists for must NOT be caught: an on-chain credential hash
#    under a field name containing "key", which is the exact shape proposal metadata carries.
# The hash is split for the same reason the plants are: this file is scanned too, and a bare
# 56-hex value next to the word "keyHash" is exactly what generic-api-key matches.
HASH="863ae82daba6a0044c651216""e4989b45044b07296533e6a3daf338cd"
printf '{ "proposal_description": { "tag": "NewCommittee",\n    "contents": [ { "keyHash": "%s" } ] } }\n' \
  "$HASH" > "$DECOY"
if scan; then
  echo "  ok   an on-chain keyHash in $REL does not trip the gate"
else
  echo "  FAIL an on-chain keyHash in $REL trips the gate, so the allowlist is not working"
  fail=1
fi
rm -f "$DECOY"

# 3. The bech32-governance-identifier entry is scoped by VALUE SHAPE, not by path, so both halves
#    are planted in a Haskell source file under the same binding name that tripped the gate —
#    `drepKeyBech32` in `UnitTests/WritePath.hs`, whose "Key" is what `generic-api-key` read.
#
#    First half: the narrowing must not excuse the binding. An AWS key id assigned to that exact
#    name is still a leak, and if this stops failing the entry has gone from value-scoped to
#    name-scoped without anyone editing it.
HS_DIR="$ROOT/src/test/UnitTests"
HS="$HS_DIR/ZzPlanted.hs"
mkdir -p "$HS_DIR"
printf 'module ZzPlanted where\n\ndrepKeyBech32 :: String\ndrepKeyBech32 = "%s"\n' "$AWS" > "$HS"
if scan; then
  echo "  FAIL a planted AWS key under a 'Key'-named binding did NOT trip the gate"
  fail=1
else
  echo "  ok   a planted AWS key under a 'Key'-named binding still trips the gate"
fi

#    Second half: the identifier the entry exists for. Split for the same reason every other plant
#    here is — this file is scanned too, and the point is that the CONFIG allows this shape, not
#    that this script is exempt from its own test.
DREP="drep1y2qn0rf74zdk3u8""upx2yk8un7tlts5f33uvklx96gq5a32qmwj3xg"
printf 'module ZzPlanted where\n\ndrepKeyBech32 :: String\ndrepKeyBech32 = "%s"\n' "$DREP" > "$HS"
if scan; then
  echo "  ok   a bech32 DRep id under a 'Key'-named binding does not trip the gate"
else
  echo "  FAIL a bech32 DRep id under a 'Key'-named binding trips the gate"
  fail=1
fi

# 4. The raw-credential entry, the same value in the other encoding. It fired at
#    `UnitTests/AttestRead.hs:126` under `hexCredential`, so that is the binding name used here.
#
#    This entry is bounded by a WIDTH — 56 hex characters, 28 bytes, blake2b-224 — so it takes three
#    plants and not two. The third is the one that matters: a 64-hex value under the same name must
#    still be caught, because if it is not, the entry has stopped meaning "a credential hash" and
#    started meaning "hex is fine", which is a hole big enough for an actual key.
#
#    The 64-hex plant is HIGH ENTROPY on purpose. Measured while writing this: a 64-hex value of
#    `aa` followed by zeros is not flagged by `generic-api-key` at all, so using one here would have
#    produced a passing assertion that proves nothing about the allowlist.
HEX56="81378d3ea89b68f0fc09944b1f93f2feb8""51318f196f98ba4029d8a8"
HEX64="9f3c1d7ba8e24056c1fb09d4e7a3528b""46d0ea91c7f5382604bd1a9e8c73f501"
plant_hex() { printf 'module ZzPlanted where\n\nhexCredential :: String\nhexCredential = "%s"\n' "$1" > "$HS"; }

plant_hex "$HEX56"
if scan; then
  echo "  ok   a 28-byte credential hash under a 'Credential'-named binding does not trip the gate"
else
  echo "  FAIL a 28-byte credential hash under a 'Credential'-named binding trips the gate"
  fail=1
fi

plant_hex "$AWS"
if scan; then
  echo "  FAIL a planted AWS key under a 'Credential'-named binding did NOT trip the gate"
  fail=1
else
  echo "  ok   a planted AWS key under a 'Credential'-named binding still trips the gate"
fi

plant_hex "$HEX64"
if scan; then
  echo "  FAIL a 32-byte hex value is excused, so the allowlist reads 'hex' and not '28 bytes'"
  fail=1
else
  echo "  ok   a 32-byte hex value under the same binding still trips the gate"
fi
rm -rf "$ROOT/src"

if [ "$fail" = 0 ]; then echo "allowlist OK"; else echo "allowlist FAILED" >&2; fi
exit $fail
