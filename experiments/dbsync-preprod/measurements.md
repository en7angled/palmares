# Experiment A — measurements

Appended to by `./measure.sh`, one `##` section per run. See README.md §"Reading the results".

Stack under measurement:

| | |
|---|---|
| db-sync | `ghcr.io/blinklabs-io/cardano-db-sync:13.7.1.0@sha256:2a341eb3…54eb950` (arm64), cap 2.0 CPU / 6144M |
| node | `ghcr.io/blinklabs-io/cardano-node:11.1.2@sha256:3620624c…62c11d` (arm64), cap 1.0 CPU / 3584M |
| postgres | `postgres:17-alpine@sha256:b0f9560a…52b24` (arm64/v8), cap 0.75 CPU / 2048M |
| insert_options | `preset: only_governance` + `offchain_vote_data: enable` + `shelley: {enable: true}` |
| host | macOS aarch64, Docker 29.8.2, 4 CPU, 16.5 GB RAM |

<!-- measure.sh appends below this line -->
