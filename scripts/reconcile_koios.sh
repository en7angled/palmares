#!/usr/bin/env bash
# F1 check 6 — external parity against Koios preprod. A thin wrapper over `admin reconcile-koios`.
#
# Koios runs on cardano-db-sync too: it is a completeness check, never a source of truth, and never
# a fallback when our own sync is behind.
#
# The wrapper exists for one reason — to PROPAGATE the exe's exit code while still printing the
# per-row table. `set -e` would abort at the failing command and never reach the `case`, which is
# why the call is guarded with `|| rc=$?`: the four codes are the command's whole contract with the
# nightly, and a wrapper that swallowed them would turn every outcome into "the script ran".
set -euo pipefail

: "${PALMARES_API:?set PALMARES_API, e.g. https://gov.cardano.vip/api}"
: "${KOIOS_API:=https://preprod.koios.rest/api/v1}"
# Overridden in CI to `docker run … ghcr.io/<owner>/palmares-admin:latest`, so the same script runs
# locally against cabal and in the workflow against the published image.
: "${PALMARES_ADMIN_CMD:=cabal run -v0 admin --}"
export KOIOS_API

mkdir -p out
rc=0
${PALMARES_ADMIN_CMD} reconcile-koios --out out/divergences.json "$@" || rc=$?

case $rc in
  0) echo "parity: 0 unexplained divergences" ;;
  1) echo "parity: UNEXPLAINED DIVERGENCES — out/divergences.json" ;;
  2) echo "parity: transport failure — our API or Koios unreachable" ;;
  3) echo "parity: ABORTED (R10) — db-sync behind, or epoch skew > 1" ;;
  *) echo "parity: unexpected exit $rc" ;;
esac

# The per-row table, which is why there is no markdown report: one rendering of these numbers.
if [ -f out/divergences.json ]; then
  jq -r '.rows[] | "\(.row)\t\(.status)\tcompared=\(.compared)\tunexplained=\(.unexplained|length)"' \
    out/divergences.json
fi

exit $rc
