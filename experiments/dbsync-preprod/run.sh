#!/usr/bin/env bash
# Start (or resume) Experiment A. Idempotent: re-running is a no-op on a healthy stack and a
# resume after `docker compose stop` or a reboot. Needs no secret.
set -euo pipefail
cd "$(dirname "$0")"

# The pinned node config set is the one input that must not drift: db-sync replays the ledger
# against these genesis files, so a truncated or edited fetch silently invalidates the whole
# measurement. Fail closed.
(cd node-config && shasum -a 256 -c SOURCES.sha256)

docker compose config -q
docker compose up -d

echo
docker compose ps
cat <<'EOF'

Started. The node restores from Mithril first (~20-40 min, no socket until it finishes), then
db-sync begins its from-genesis pass.

  docker compose logs -f cardano-db-sync     # watch it
  ./measure.sh                               # append a row to measurements.md (run it hourly)
  docker compose stop                        # pause; ./run.sh resumes from the last stored block
EOF
