# ADR 0002 — Write-path chain provider

Status: proposed
Date: 2026-10-20

## Decision

Transaction building (attestation claims, countersignatures, disputes) uses **Atlas 0.14.1** with a
commercial chain provider (Maestro), whose token is supplied from the environment and never committed.
The read path stays fully self-hostable; only the write path needs a key.

Rationale: Atlas's Ogmios provider targets Ogmios v6 and no Atlas release has shipped since Ogmios v7's
breaking schema change, so a local-node-over-Ogmios write path is not available today.

## Spike

To be run post-F0, non-blocking: evaluate Atlas's **local-node** provider against the preprod node we
already run, which would remove the provider dependency entirely. Note that Atlas has **no** db-sync
provider — that option does not exist, despite the convenient fact that db-sync is already deployed.

Outcome to record here: whether the local-node provider can build and submit the attestation transaction
set, and what it costs in operational complexity versus one provider token.

## Consequences

- The self-hosting claim in the README is worded as "two doors": the read path needs nothing, the write
  path needs your own token.
- A provider token is the only secret in the deployment. It is injected from the environment, excluded by
  both `.gitignore` and `.dockerignore`, and must never reach a client bundle.
