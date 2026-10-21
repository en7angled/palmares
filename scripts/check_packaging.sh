#!/usr/bin/env bash
# Every path in the cabal file's `extra-source-files`, and `license-file`, must be COPYed into the
# builder stage of all four service Dockerfiles.
#
# WHY THIS EXISTS. `cabal install` builds an sdist first, and an `extra-source-files` glob that
# matches nothing is a hard error there — not a warning. So a path added to the cabal file without a
# matching COPY fails the IMAGE build and nothing else: `cabal build`, `cabal test` and CI all stay
# green, because the file is present in the working tree. The cabal file carries a comment saying
# exactly this. The comment did not stop it: `resources/` was added for the metrics catalogue, no
# Dockerfile was touched, and the first image run after the repository transfer died four times with
#
#   cabal: sdist of palmares-0.1.0: filepath wildcard
#   'resources/metric-formulas.json' does not match any files.
#
# after an hour of building the shared base image. This check costs under a second and turns that
# into a CI failure on the commit that causes it.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re, sys

cabal = open("palmares.cabal").read()

block = re.search(r"^extra-source-files:\n((?:  \S.*\n)+)", cabal, re.M)
if not block:
    sys.exit("check_packaging: no extra-source-files block in palmares.cabal")

paths = [l.strip() for l in block.group(1).splitlines() if l.strip()]
paths.append(re.search(r"^license-file:\s*(\S+)", cabal, re.M).group(1))

DOCKERFILES = [
    "Dockerfile.admin",
    "Dockerfile.query-api",
    "Dockerfile.interaction-api",
    "Dockerfile.attest-sync",
]


def copied_sources(path):
    """Every build-context source a Dockerfile COPYs, destination and --from stages excluded."""
    out = []
    for line in open(path):
        line = line.strip()
        if not line.startswith("COPY ") or "--from=" in line:
            continue
        parts = line.split()[1:]
        out += [p.lstrip("./") for p in parts[:-1]]
    return out


missing = []
for dockerfile in DOCKERFILES:
    sources = copied_sources(dockerfile)
    for p in paths:
        # A COPY of a directory covers everything under it, so compare against the path's directory
        # as well as the path itself — `COPY sql ./sql` covers `sql/indexes/*.sql`.
        d = os.path.dirname(p) or p
        covered = any(
            p == s or d == s or d.startswith(s + "/")
            for s in sources
        )
        if not covered:
            missing.append((p, dockerfile))

if missing:
    print("check_packaging: extra-source-files paths not COPYed into the image build context:\n")
    for p, dockerfile in missing:
        print(f"  {p}  ->  missing from {dockerfile}")
    print(
        "\n`cabal install` fails its sdist step on a glob that matches nothing, so this breaks the\n"
        "image build only — every local build and test stays green. Add the COPY."
    )
    sys.exit(1)

print(f"check_packaging: OK — {len(paths)} packaged paths COPYed by all {len(DOCKERFILES)} service Dockerfiles")
PY
