#!/usr/bin/env bash
# Two "a path must be registered in more than one place" checks, both under a second.
#
#   1. Every path in the cabal file's `extra-source-files`, and `license-file`, must be COPYed into
#      the builder stage of all four service Dockerfiles.
#   2. Every path any `embedFile` reads must be in `extra-source-files` AND in the `dist-newstyle`
#      cache key in `.github/workflows/ci.yml`, and must be counted by the embed-vs-disk case in
#      `src/test/UnitTests/Views.hs`.
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

# ---------------------------------------------------------------------------------------------
# Part 2: every `embedFile` input is registered everywhere it has to be.
#
# WHY THIS EXISTS. cabal does not track `embedFile` dependencies under this toolchain — measured:
# editing one line of `sql/030_metrics.sql` recompiles nothing. So the `dist-newstyle` cache key is
# what stands between a pull request touching only SQL and a CI run that tests the previous bytes
# against the previous bytes. That is not hypothetical: it is how a family of SQL defects stayed
# invisible, including an `admin write-metrics-doc` diff that compared the old embed with the old
# document and passed.
#
# The key was repaired by hand to name `palmares.cabal`, `sql/**` and `resources/**`, and
# `test/fixtures/dbsync-skeleton.sql` was still missing — the shape every database test is built on.
# A comment claiming the list is complete is what let that happen, so the list is DERIVED here
# instead: the embed paths come out of the sources, and each one has to be matched by a glob in the
# key, be in `extra-source-files`, and be counted by the Views case. Add an `embedFile` and this
# fails in under a second naming the three places to update.
python3 - <<'PY'
import pathlib, re, sys

cabal = open("palmares.cabal").read()
packaged = [
    l.strip()
    for l in re.search(r"^extra-source-files:\n((?:  \S.*\n)+)", cabal, re.M).group(1).splitlines()
    if l.strip()
]

# `makeRelativeToProject` is mandatory for an embed (a bare `embedFile` resolves against the
# compile-time working directory, which differs in the Docker build), so a bare one is a defect in
# its own right rather than merely a path this check cannot see.
embeds, bare = set(), []
for src in sorted(pathlib.Path("src").rglob("*.hs")):
    text = src.read_text()
    embeds |= set(re.findall(r'makeRelativeToProject\s+"([^"]+)"', text))
    bare += [
        f"{src}: {m.group(0)}"
        for m in re.finditer(r'\b(embedFile|embedDir|embedStringFile)\s+"([^"]+)"', text)
    ]
embeds = sorted(embeds)

# The dist-newstyle cache key's globs. The STORE cache is deliberately not checked: it is
# content-addressed, so restoring an older entry can only ever supply packages that are correct.
ci = open(".github/workflows/ci.yml").read()
key = re.search(r"key:[^\n]*-dist-\$\{\{\s*hashFiles\(([^)]*)\)", ci)
if not key:
    sys.exit("check_packaging: no dist-newstyle cache key with hashFiles() in .github/workflows/ci.yml")
globs = re.findall(r"'([^']+)'", key.group(1))


def glob_re(g):
    """GitHub's hashFiles globbing: `**` crosses directories, `*` does not."""
    out = ""
    i = 0
    while i < len(g):
        if g.startswith("**", i):
            out += ".*"
            i += 2
        elif g[i] == "*":
            out += "[^/]*"
            i += 1
        else:
            out += re.escape(g[i])
            i += 1
    return re.compile("^" + out + "$")


patterns = [glob_re(g) for g in globs]


def packaged_by(p):
    """extra-source-files entries are cabal globs, and only ever `dir/*.ext` or a literal here."""
    return any(glob_re(e).match(p) for e in packaged)


problems = [f"bare embed, use makeRelativeToProject: {b}" for b in bare]
problems += [
    f"{p}  ->  matched by no glob in the dist-newstyle cache key ({', '.join(globs)})"
    for p in embeds
    if not any(r.match(p) for r in patterns)
]
problems += [f"{p}  ->  not in extra-source-files" for p in embeds if not packaged_by(p)]

# The embed-vs-disk case in UnitTests.Views builds its list from three other lists, so there is no
# literal path to grep for. The COUNT is the lock instead: it is pinned in the test and derived
# here, so neither side can gain an embed without the other saying so.
pinned = re.search(
    r"length embeds @\?= (\d+)", open("src/test/UnitTests/Views.hs").read()
)
if not pinned:
    problems.append(
        "src/test/UnitTests/Views.hs no longer pins `length embeds @?= <n>`, so the "
        "embed-vs-disk case has stopped claiming to cover every embed"
    )
elif int(pinned.group(1)) != len(embeds):
    problems.append(
        f"src/test/UnitTests/Views.hs pins `length embeds @?= {pinned.group(1)}` but "
        f"src/ embeds {len(embeds)} files — add the new one to that test's list"
    )

if problems:
    print("check_packaging: embedFile inputs are not registered everywhere they have to be:\n")
    for p in problems:
        print(f"  {p}")
    print(
        "\ncabal does not track embedFile dependencies here, so a path missing from the cache key\n"
        "means CI can test the previous bytes against the previous bytes and stay green."
    )
    sys.exit(1)

print(f"check_packaging: OK — {len(embeds)} embedFile inputs in the cache key, the sdist and the Views case")
PY
