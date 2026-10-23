# ADR 0004 — Maestro withdrew its Cardano API; the write path moves to Blockfrost

Status: accepted 2026-10-23, forced by the provider, superseding [ADR 0002](0002-write-path-provider.md)
Date: 2026-10-23

## What happened

ADR 0002 chose Maestro. Maestro left Cardano.

The first symptom was the first deploy attempt, which never reached the chain:

```
admin: MspvApiError "SlotOfCurrentBlock" (ServantClientError (ConnectionError (HttpExceptionRequest
  host = "preprod.gomaestro-api.org" ... path = "/v1/chain-tip"
  (ConnectionFailure Network.Socket.getAddrInfo ...: does not exist
   (nodename nor servname provided, or not known))
```

`does not exist` is a **resolver** answer, not an HTTP one. Nothing was down, rate-limited or
unauthorised: the hostname has no address. Measured 2026-10-23:

| probe | result |
| --- | --- |
| `dig @8.8.8.8 preprod.gomaestro-api.org` | empty |
| `dig @ali.ns.cloudflare.com preprod.gomaestro-api.org A` (the zone's own authoritative NS) | empty |
| same, for `mainnet.gomaestro-api.org` and the apex `gomaestro-api.org` | empty |
| `curl https://docs.developer.gomaestro.org/` | `000` — does not serve |
| `status.gomaestro.org` service list | Mezzamine App, Treasury App, two landing pages. **No Cardano API.** |
| `gh api repos/maestro-org/haskell-sdk --jq .archived` | `true`, last push **2026-04-30** |
| `gh api repos/maestro-org/typescript-sdk --jq .archived` | `true`, last push **2026-04-30** |
| `gh api orgs/maestro-org --jq .description` | **"A Bitcoin capital allocation platform"** |

An empty answer from the zone's *own* nameservers is the decisive one — a local resolver or a
network block cannot produce that. The SDKs were archived at the end of April 2026 and the API DNS
has since been withdrawn. This is a company exit from the chain, not an outage, so there is nothing
to wait for and no status page to watch.

It was already known one repo over. `apps-k8s-configs/chains/cardano/mainnet/README.md` records that
**TOA mainnet and delegation prod already moved to `GYBlockfrost`** in `ATLAS_CORE_CONFIG` ("Maestro
și-a retras API-ul"), and the delegation-service dev overlay was deleted on 2026-10-18 partly because
"secretul lui era pe providerul Maestro retras". palmares simply had not been told.

## Decision

The write path uses Atlas's **`GYBlockfrost`** provider: `{"blockfrostKey": "preprod…"}` as
`coreProvider`. This is a **configuration change only** — no Haskell changes at all.

Three facts make it that cheap, and each was checked rather than assumed:

* Atlas 0.14.1's `GYCoreProviderInfo` is an **untagged** sum (`sumEncoding = UntaggedValue`,
  `GYConfig.hs:109-121`). The provider is selected by *which keys are present*, so swapping it is one
  JSON object. The corollary is a footgun worth naming: **never put two providers' keys in one
  object**, because the first constructor that parses wins.
* palmares asks Atlas for exactly six things — protocol parameters, slot, UTxO query, datum lookup,
  submit, await-confirmed — and all six are implemented by the Blockfrost provider. The functions
  that `error` out in `Providers/Blockfrost.hs` are `blockfrostGovState`, `blockfrostDRepState`,
  `blockfrostDRepsState`, `blockfrostConstitution`, `blockfrostProposals` and
  `blockfrostMempoolTxs` — **governance queries, which palmares never routes through Atlas.** Its
  governance data comes from db-sync and Koios (ADR 0001), and `grep` confirms it imports no Atlas
  governance module. A governance registry that read DReps through its transaction builder would
  have been blocked here; this one is not, and that is a consequence of D-1, not luck.
* `providerFamily` in `interaction-api/ServiceStatus.hs:124-128` already enumerates all four
  providers, `GYBlockfrost {} = "blockfrost"` included, so `/status` reports the new family with no
  edit. query-api needs no provider at all.

`turboSubmit` is dropped with the Maestro block. It was a Maestro-only submission hint
(`MaestroApi.maestroSubmitTx (Just True == turboSubmit)`), it has no Blockfrost equivalent, and
leaving the key in an otherwise-Blockfrost object is the two-providers footgun above.

## The alternative, and why it looked like the weaker one

*Written before the deploy. The section after it records what happened when the alternative was
actually tried, and it inverts the recommendation for a single-machine deployment — kept in this
order because the two reasons below are still exactly true, and only one of them turned out to
matter.*

`GYNodeKupo` — `{"socketPath": …, "kupoUrl": …}` — would remove the third-party dependency entirely,
which is what ADR 0002's Spike section set out to evaluate. The infrastructure for it is already
running and already synced: node 11.1.2 healthy, Kupo v2.12.0 at the tip with `--match '*'`
(`kupo_network_synchronization 1.0`, checkpoint == node tip), and `compose.yaml` already defines the
`kupo` service under the `write` profile with that reasoning written out.

It is not the decision for two reasons, one local and one general:

* **On macOS the host cannot reach the node socket.** It lives in a *named* Docker volume precisely
  because, as `experiments/dbsync-preprod/compose.yaml:55` puts it, "A UNIX socket in a macOS bind
  mount does not work." The admin CLI runs on the host. Bridging it (container-side socat →
  host-side relay) is throwaway plumbing for one command.
* **It does not fix a deployed service.** `interaction-api` in a cluster cannot reach a laptop's
  socket either. A hosted provider fixes the deploy *and* the running write path with the same key;
  the socket bridge fixes only whichever machine is holding it.

`GYNodeKupo` remains the right end state for an operator who runs the whole stack in one place — the
Belt System's dev overlay took exactly that route.

## Measured 2026-10-23: the local-node path works, and it is what deployed F1

ADR 0002's spike asked "whether the local-node provider can build and submit the attestation
transaction set, and what it costs in operational complexity versus one provider token." **It can.**
The first palmares deployment was made through `GYNodeKupo`, not through a hosted provider: six
transactions built, submitted and awaited to confirmation against cardano-node 11.1.2 and Kupo
v2.12.0 — one reference script per validator, the minting policy, and the oracle NFT mint that locks
the genesis `OracleParams`. `admin query-oracle` then read the datum back through the same provider.

What it cost, precisely: **6.97 tADA burned**, plus **205.40 tADA locked** as min-ADA in the five
reference-script UTxOs, which is recoverable by spending them. The earlier "~210 tADA" figure was the
*balance you must hold*, not the price — a distinction worth keeping, because the deploy looks thirty
times more expensive than it is.

The operational complexity is one platform quirk and nothing else. On a Linux host the node socket is
a path and there is no bridge at all. On macOS the socket lives in a named Docker volume, so it takes
two hops to reach a host-run CLI — a socat container publishing it on loopback TCP, and a small
UNIX-socket relay on the host. That is a laptop problem, not an architecture one.

**So this ADR's decision is narrower than it first reads.** `blockfrostKey` is the answer for a
service that does not sit beside a node — an `interaction-api` in a cluster, or any deployment where
the write path and the node are on different machines. For a single-machine deployment the honest
recommendation is now `GYNodeKupo`, because it is measured, it needs no account, and it leaves the
protocol with **no secret at all** on the write path. ADR 0002's spike is closed, and it closed in
favour of the option it was written to hope for.

`GYOgmiosKupo` stays unavailable for the reason ADR 0002 already gave: node 11.1.2 requires Ogmios
v7 and no Atlas release has shipped against v7's schema change.

## Consequences

* **The committed template changes.** `config/config_atlas.example.json` carried a `maestroToken`
  pointing at a host that no longer resolves, so anyone following the README reproduced the failure
  above. It now carries `blockfrostKey`.
* **A Blockfrost key is per-network.** The cluster's existing keys are mainnet and preview; preprod
  needs its own project. This is the one step that cannot be done from the repo.
* **§2's "two doors" is unchanged in substance.** The read path still needs no account; the write
  path still needs one key of your own. Only the vendor behind that sentence moved.
* **One secret, one shape, across the estate.** `GYBlockfrost` in `ATLAS_CORE_CONFIG` is now what
  TOA mainnet, delegation prod and palmares all use, which makes the SOPS entry and the rotation
  story the same everywhere.
* **The lesson is cheap to state and was expensive to find.** A provider's DNS is a dependency with
  no status page. The failure arrives as a resolver error inside a library error inside a CLI error,
  and the first instinct — a sandbox, a token, a typo — is wrong three times before the authoritative
  nameserver settles it. When a provider call fails, resolve the hostname first.
