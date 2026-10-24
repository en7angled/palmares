# Running the attestation flow smoke test

`scripts/smoke_attest_flow.sh` drives one claim → attest → verify round trip against a live
deployment and asserts the projection at every step. It is F1 check 11. This page exists for one
reason: the script needs a **signer**, and that is not obvious from the API.

## Why a signer is configuration

Every write route on the interaction API returns an **unsigned** transaction and nothing else, and
`/submit-tx` takes `{tx_unsigned, tx_wit}`. There is no route that signs, and no key in any
service. So the script cannot complete a transaction on its own.

The `admin` CLI does build-and-sign in one step — but only for the commands it has, and it has
none of the three this flow needs:

| flow step | admin CLI command | over HTTP |
|---|---|---|
| claim a profile | **none** | `/claim-profile` |
| issue an attestation | `issue-attestation` | `/issue-attestation` |
| accept an attestation | `accept-attestation` | `/accept-attestation` |
| open a dispute | **none** | `/open-dispute` |
| resolve a dispute | **none** | `/resolve-dispute` |

So the script goes over HTTP for all six, uniformly, and takes the signature as a command.

`resolve-dispute` being on HTTP is deliberate and not an oversight: the oracle validator requires
the admin's signature on chain, so the service can only ever return an unsigned transaction, and
there that transaction **is** the product — a verdict a disputing party asked for. That is the
documented contrast with `AdminActionType`, every constructor of which is refused in a request
body. See `DomainTypes/Core/Actions.hs`.

## The signer contract

```
stdin  : the unsigned transaction's CBOR hex, exactly as the write route returned it
stdout : a CIP-30 shaped witness SET CBOR hex, e.g. a1008182582064...01
```

That is what a wallet's `api.signTx` returns and what `tx_wit` parses (Atlas `GYTxWitness` is a
`AlonzoTxWits ConwayEra` read from hex). It is **not** a `cardano-cli` text envelope, and **not** a
bare key witness: `cardano-cli transaction witness` emits a single witness with cardano-api's own
discriminator in front of it, which does not decode as a witness set.

Two signers, because two different keys are required:

- `PALMARES_SIGN_CMD` — the wallet that holds the profile user tokens. Claims, the attestation, the
  acceptance and the dispute.
- `PALMARES_ADMIN_SIGN_CMD` — the oracle admin. The resolution only. Defaults to
  `PALMARES_SIGN_CMD`, which is right when one operator runs both on a preprod box.

## The signer the repo ships

`admin sign-tx`. It reads the unsigned transaction's CBOR hex on stdin, signs with `operation.prv`,
and writes the witness set's hex on stdout — the contract above, and nothing else on stdout.

```bash
export PALMARES_SIGN_CMD='cabal run -v0 admin -- sign-tx'
# or, with the published image:
# PALMARES_SIGN_CMD='docker run --rm -i -v "$PWD":/w -w /w ghcr.io/<owner>/palmares-admin:latest sign-tx'
```

For a long time the repo shipped **no** signer, on purpose, because a wrong one would have looked
like a convenience. What changed is not that the risk went away but that there is now one signer
whose encoding cannot be a guess: the witness set comes out of the same `GYTxWitness` that
`makeSignedTransaction` consumes, through the ledger's own CBOR and the ledger's own hex, and the
body is recovered with the same `getTxBody` the API applies to `tx_unsigned`. Both halves of the
round trip are the code `/submit-tx` runs. `UnitTests.SignTx` pins it.

It needs **no provider, no `config_atlas.json` and no network** — a signature is a function of the
transaction and the key — so it is dispatched beside `operator-address`, before any provider loads.
`operation.prv` is the only thing it reads besides stdin.

`PALMARES_ADMIN_SIGN_CMD` can stay at its default here: `sign-tx` signs with whatever key
`operation.prv` holds, so one checkout signs as one identity. Two identities means two working
directories, each with its own `operation.prv`, and the second one named in
`PALMARES_ADMIN_SIGN_CMD`.

**It cannot tell you whether the key is the right one.** `sign-tx` signs; the node is what refuses a
transaction whose required signature is missing. So the other two values have to agree with
`operation.prv`:

- `ATTEST_SMOKE_ADDR` — `admin operator-address` prints it, in the raw hex form the request fields
  want. Take it from there rather than from a wallet, and the address and the signature cannot
  belong to different keys.
- `ATTEST_SMOKE_DREP_ID` — must be the DRep credential of that same key (see below).
  `operator-address` prints it too, as the first line and **before the Atlas config loads**: a
  CIP-129 credential carries no network byte, so it is available even when the provider config is
  not. Take it from there; slicing the hash out of the address hex is deriving it with a second
  tool.

## Two values that are easy to get wrong

**`ATTEST_SMOKE_ADDR` is raw CBOR hex, not bech32.** `GYAddress`'s `FromJSON` goes through
`FromHttpApiData`, which is `deserialiseFromRawBytesHex`; `addr_test1…` is refused. The generated
document's `GYAddress` *description* says bech32 and is wrong about it — its `format: cbor hex`,
its 114-character length and its example are right. `scripts/smoke_interaction_api.sh` uses the hex
form for the same reason.

**`ATTEST_SMOKE_DREP_ID` must be the DRep credential of the key the signer signs with.** Claiming a
key credential puts `mustBeSignedBy <that key hash>` into the transaction
(`TxBuilding/Operations.hs`, `claimProofSkeleton`), so any other DRep id — a golden test vector,
say — builds a transaction that cannot be signed. It must be the CIP-129 `drep1y…` form: the
`/profiles/by-credential/` lookup accepts no other, and the script asserts both refusals.

## Running it

```bash
export PALMARES_INTERACTION_API=https://gov.cardano.vip/api   # default http://localhost:8082
export PALMARES_QUERY_API=https://gov.cardano.vip/query       # default http://localhost:8083
export BASIC_USER=… BASIC_PASS=…
export ATTEST_SMOKE_ADDR=00e1cbb80d…                          # 114 hex characters
export ATTEST_SMOKE_DREP_ID=drep1y…
export PALMARES_SIGN_CMD='cabal run -v0 admin -- sign-tx'
# PALMARES_ADMIN_SIGN_CMD defaults to the above
# PALMARES_ADMIN_CMD defaults to "cabal run -v0 admin --"; in CI, the published image:
#   PALMARES_ADMIN_CMD='docker run --rm -v "$PWD":/w -w /w ghcr.io/<owner>/palmares-admin:latest'
./scripts/smoke_attest_flow.sh
```

`PALMARES_ADMIN_CMD` is used **read-only**, for `query-oracle`, so the dispute deposit the
projection publishes is compared with the oracle's own parameter rather than with "some positive
integer". It still needs `operation.prv` and the Atlas config beside it — unlike the `sign-tx`
invocation above, which is the same binary but needs neither the config nor a provider.

Exit codes:

| code | meaning |
|---|---|
| 0 | all six steps passed |
| 1 | the flow completed and an **assertion** failed — the API answered with a wrong value |
| 2 | the flow could not be driven: preflight refused, a write failed, a projection never appeared |

The distinction is the point: 1 is a defect in the registry, 2 is a defect in — or an absence of —
the deployment under it.

## When a projection never appears

The read surface is fed by `attest-sync`, asynchronously, so the script polls with a bounded
timeout (`ATTEST_SMOKE_TIMEOUT`, default 600s) rather than sleeping a guess.

**The projector now reports itself, and `query-api` publishes it** (`CS-07`). `attest-sync` writes a
singleton `palmares_attest.attest_sync_state` row on every tick and again after every fetch window,
and `/status` carries it as `attestation`: the applied slot, Kupo's tip as the projector last saw it,
the lag, `state` (`syncing` | `following` | `rolled_back` | `error`), `last_sync_at`, `is_ready`
(a pass completed with the cursor at Kupo's tip), the policy it follows and the last error. The same
three facts travel on every response as `X-Attest-Slot`, `X-Attest-Lag-Seconds` and
`X-Attest-State`.

So a poll that times out in step 2 is now diagnosable from one request: `attestation: null` means
this database has no projector at all, `state: "syncing"` means the backfill is still running,
`state: "error"` means a tick raised and `attest_dead_letter` says what, and a `last_sync_at` minutes
old means the projector is dead whatever its cursor says.

`/ready` turns red on the last two — an errored tick and a report that stopped arriving — and
deliberately NOT on `syncing`: a projector mid-backfill is a healthy service serving honest partial
attestation pages, and taking the governance routes out of rotation for the hours a backfill takes
would be the worse answer. The old `attest_lag_seconds` field stays beside the new block.

## What it leaves behind

Two profiles, one accepted attestation and one upheld dispute, all named `palmares-<tag>-*`, and
the script prints their URLs. Nothing is cleaned up: an attestation is a permanent historical fact,
which is also why the admin CLI has no `delete-profile`. Re-running is safe — every name carries a
fresh run tag — except that a second claim of the same DRep credential makes
`/profiles/by-credential/` report more than one claimant, which is a real state the API refuses to
pick a winner for. The script asserts `total >= 1` and membership for that reason, not `total == 1`.
