#!/usr/bin/env bash
# The domain is attestation, everywhere — asserted over the tree rather than trusted.
#
# __Why this is a script and not a Haskell test.__ Plan B's T-ATTEST-1 step 1 specifies a test module
# that greps embedded sources. Embedding ~30 Haskell files into the test binary to grep them would mean
# listing every one in `extra-source-files` and re-embedding on every edit, to do what grep does. This
# repo already has a family of CI check scripts — check_swagger.sh, check_roles.sh,
# check_gitleaks_allowlist.sh — and this belongs to it. (Builder decision, documented here rather than
# silently.)
#
# __Why it exists at all.__ The rename's failure mode is PARTIAL: the compiler is perfectly happy with
# half of it, and the halves that reach a user — a Swagger title, an error message — are the ones the
# compiler never looks at. The layers currently disagree on the noun: on-chain says attestation
# (`AttestationsValidator`, `ctxAttestationsAddress`) while the DTOs, the routes and the projection
# columns say achievement.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0

# Everything we own. dist-newstyle and .git excluded; `docs/` excluded because a historical note may
# legitimately say what the Belt System called something.
# The dormant emulator modules are comment-prefixed out of the test-suite's `other-modules`, so
# nothing compiles them, and plan B's T-ATTEST-5 rewrites them wholesale. Excluded by name rather
# than by pattern, so that re-landing one in the cabal file brings it under this guard with no edit
# here: the exclusion is a list of files, and a file dropped from the list is covered again.
# query-api's three attestation read modules are dormant for the same reason and, unlike the test
# modules, are already broken against the live DTOs — Query/Projected.hs reads
# `searchResultsPractitioners`, a field QueryResponses.hs no longer has. A mechanical rename would not
# make them compile, so T-ATTEST-9 rebuilds them over palmares_attest instead.
DORMANT='src/test/TestRuns.hs src/test/Test/Fixtures.hs src/test/UnitTests/Attestation.hs src/test/UnitTests/Cleanup.hs src/test/UnitTests/Oracle.hs src/exe/query-api/Query/Projected.hs src/exe/query-api/Query/Aggregates.hs src/exe/query-api/Query/Pages.hs'

sources() {
  find src sql scripts config -type f \( -name '*.hs' -o -name '*.sql' -o -name '*.sh' -o -name '*.json' -o -name '*.yaml' \) \
    ! -name 'check_vocabulary.sh' 2>/dev/null | grep -vFx -e "$(echo $DORMANT | tr ' ' '\n' | paste -sd$'\n' -)" 2>/dev/null \
    || find src sql scripts config -type f \( -name '*.hs' -o -name '*.sql' -o -name '*.sh' -o -name '*.json' -o -name '*.yaml' \) \
      ! -name 'check_vocabulary.sh' 2>/dev/null
}

banned() {
  local label="$1" pattern="$2"
  local hits
  hits="$(sources | xargs grep -nE "$pattern" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "FAIL $label"
    echo "$hits" | head -25 | sed 's/^/       /'
    local n
    n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    [ "$n" -gt 25 ] && echo "       ... and $((n - 25)) more"
    fail=1
  else
    echo "ok   $label"
  fi
}

echo "# Vocabulary — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# The noun. This is the whole point of the rename: one word for the thing the registry records.
banned "no source says achievement" '[Aa]chievement'

# The inherited domain. Two words need anchoring rather than banning outright, because the governance
# domain uses them legitimately:
#
#   * `membership` is the Koios parity report's own field name — `Divergence k "membership" ...` means
#     a key present on one side only (Reconcile.hs:178-179), and committee membership is a real
#     governance concept. So the pattern names the BJJ compounds, not the word.
#   * `rank` would match any future governance ranking, so it names the BJJ identifiers that existed.
# `Belt System` is excluded here on purpose: a comment explaining why something is the way it is
# ("snake_case, not the inherited PascalCase") is provenance worth keeping, and what a USER reads is
# checked separately below.
banned "no source says practitioner, belt, promotion or dojo" \
  '[Pp]ractitioner|[Bb]elt([^ -]|$)|[Pp]romotion|dojo'
banned "no source carries the BJJ rank or membership machinery" \
  'OnchainRank|rankId|[Gg]etCurrentRank|RanksValidator|MembershipsValidator|MembershipInterval|MembershipHistory|MembershipList|membershipsValidator|membership interval|membership history'

# What a USER reads, checked where they read it — not in comments. A provenance note explaining why
# something is the way it is ("snake_case, not the inherited PascalCase") is worth keeping; a Swagger
# title naming another product is not. So: the generated Swagger documents, and the exception messages.
if ls docs/generated/swagger/*.json >/dev/null 2>&1; then
  if grep -l 'Belt System' docs/generated/swagger/*.json >/dev/null 2>&1; then
    echo "FAIL a generated Swagger document names the Belt System"
    grep -l 'Belt System' docs/generated/swagger/*.json | sed 's/^/       /'
    fail=1
  else
    echo "ok   no generated Swagger document names the Belt System"
  fi
else
  echo "skip no generated Swagger yet — run the services with --write-swagger-only"
fi

if grep -rn 'Belt System' src --include='*.hs' 2>/dev/null | grep -E 'title \.~|displayException|\.= \(' >/dev/null; then
  echo "FAIL a user-facing string names the Belt System"
  grep -rn 'Belt System' src --include='*.hs' | grep -E 'title \.~|displayException|\.= \(' | sed 's/^/       /'
  fail=1
else
  echo "ok   no user-facing string names the Belt System"
fi

# One network name, wrong, in a client-facing error string (InteractionAppMonad.hs:108 said "preview"
# while the sample config says preprod — and in the same sentence said "profile fee" for a path that
# could not create profiles).
banned "no error message hardcodes a network name" '"[^"]*\b(preview|preprod|mainnet)\b[^"]*ADA'

# The licence file keeps its name — it is the licence of the project this was extracted from, and
# renaming it would misattribute it. Asserted so nobody "fixes" it.
if grep -q 'licenses/LICENSE.decentralized-belt-system.MIT' palmares.cabal; then
  echo "ok   the inherited licence keeps its own name (attribution, not a leftover)"
else
  echo "FAIL the inherited licence file reference went missing from palmares.cabal"
  fail=1
fi

# ---------------------------------------------------------------------------------------------
# Every StripPrefix must still name a prefix that exists.
#
# __The bug this caught during the attestation rename.__ `deriving-aeson`'s `StripPrefix "aar"` is a
# STRING, not a reference to the record's fields. Renaming AwardAchievementRequest's fields from
# `aar*` to `iar*` left the option naming a prefix that matched nothing — and that compiles perfectly.
# Every key would have shipped as `iar_subject_profile_id` instead of `subject_profile_id`, on a live
# route, with no error anywhere. And the prefix is written TWICE, once for `FieldLabelModifier` and
# once for `mkStripPrefixSchemaOptions` which drives Swagger, so a half-fix publishes a Swagger
# document describing fields the API rejects.
#
# The check is deliberately crude and therefore cheap: a prefix must be used by at least one
# identifier in its own file. A stale one is used by none. That is exactly the failure shape.
echo
stale=0
while IFS=: read -r file _ prefix; do
  [ -z "${prefix:-}" ] && continue
  if ! grep -qE "[^A-Za-z]${prefix}[A-Z]" "$file"; then
    echo "FAIL StripPrefix \"$prefix\" in $file names a prefix no identifier there uses"
    stale=1
    fail=1
  fi
done < <(grep -rnoE 'StripPrefix "[A-Za-z]+"' src --include='*.hs' | sed 's/StripPrefix "\([A-Za-z]*\)"/\1/')
[ "$stale" = 0 ] && echo "ok   every StripPrefix names a prefix its own file still uses"

# ---------------------------------------------------------------------------------------------
# Inherited fix #1: a FeeConfig field is named in exactly TWO places — where the record is defined,
# and in `feeFor`. Every other mention is a second naming site, and a second naming site is how the
# Belt System's interval fee came to charge the membership-history field. The type now forbids passing
# a selector; this forbids reintroducing the habit by hand.
#
# `src/exe/admin/Main.hs` is excluded: it CONSTRUCTS a FeeConfig from flags and PRINTS one back,
# and a record cannot be built or displayed without naming its fields. It never selects a fee for
# a check, which is what this invariant is about.
echo
feesites="$(grep -rlE 'fcProfileCreationFee|fcAttestationFee' src --include='*.hs' 2>/dev/null \
  | grep -vE 'Onchain/Protocol/Types\.hs$|Onchain/Protocol/Lookup\.hs$|src/test/|src/exe/admin/Main\.hs$' || true)"
if [ -n "$feesites" ]; then
  echo "FAIL a FeeConfig field is named outside Protocol/Types.hs and feeFor:"
  echo "$feesites" | sed 's/^/       /'
  fail=1
else
  echo "ok   a FeeConfig field is named only where it is defined and in feeFor"
fi

# ---------------------------------------------------------------------------------------------
# No `?` anywhere in the five schema files — not in SQL, not in a string literal, and NOT IN A
# COMMENT.
#
# `Query/Views.hs` applies each of these files WHOLE, with `rawExecute (decodeUtf8 sql) []`, and
# postgresql-simple reads `?` as a parameter placeholder in the query text it is handed. Comments
# included: it is a text formatter, not a SQL parser. So a URL in a comment is a fatal boot error.
#
# MEASURED, and it cost a full test run to find: two comments gained `/gov-actions?limit=50` while
# documenting a performance fix, and every one of the ~20 database-backed test cases failed with
# `FormatError "2 single '?' characters, but 0 parameters"` — a message that names neither the file
# nor the line, under a first line that reads "palmares schema DDL failed".
#
# `sql/indexes/*.sql`, `sql/050_roles.sql` and `sql/checks/*.sql` are deliberately NOT covered: the
# first two go through `ApplySql.splitStatements`, whose `InComment` state drops comment text before
# it reaches the driver, and the checks are run by psql. Their comments may hold a `?` and several do.
#
# The deeper fix is to apply these five through `splitStatements` as well, which exists and is tested
# — one function away. It is not taken here because that rewrites the read API's boot path, which is
# load-bearing (an unchanged restart must not rebuild the schema), to enforce a convention this gate
# enforces for four lines and no risk.
echo
qmarks="$(grep -lE '\?' sql/000_schema.sql sql/010_gov_views.sql sql/020_views.sql sql/030_metrics.sql sql/040_grants.sql 2>/dev/null || true)"
if [ -n "$qmarks" ]; then
  echo "FAIL a '?' in a schema file applied whole — postgresql-simple reads it as a placeholder:"
  echo "$qmarks" | sed 's/^/       /'
  grep -nE '\?' $qmarks | sed 's/^/         /'
  fail=1
else
  echo "ok   no schema file applied whole contains a '?'"
fi

if [ "$fail" = 0 ]; then echo "vocabulary OK"; else echo "vocabulary FAILED"; fi
exit $fail
