# Functional use cases — the frontend's input

Three documents, written to be the starting point for designing and building the explorer. They
describe what this backend can actually do, route by route and flow by flow, grounded in the code
and in live preprod responses rather than in the plan.

| Document | What it answers |
|---|---|
| [`attestation-protocol.md`](attestation-protocol.md) | The on-chain half: who can act, the twelve use cases, the three state machines, every refusal a user can hit, and what is irreversible. |
| [`governance-read-surface.md`](governance-read-surface.md) | The read half: the eighteen questions a visitor without a wallet can ask, the five DRep metrics written for a non-expert, and the freshness contract as a UI requirement. |
| [`api-screen-map.md`](api-screen-map.md) | The wire: every route on both APIs, twenty proposed screens with the calls each one makes, and the integration contract — pagination, filters, errors, identifiers, CORS, and the wallet signing sequence. |

Each ends with a **gaps** section: what a screen will obviously need that the API cannot do today.
Those are the most valuable part of the three and the reason they were written before any UI code.

## How to read them

**They were written on 2026-10-24, against the deployment made that day, while the backend was being
fixed in parallel.** Every number and every response in them was measured — none is invented — but
some were measured before the fix that followed hours later. The three documents say `UNVERIFIED:`
wherever a shape could not be captured live, which is honest and worth trusting.

**These items are already closed and the documents do not know it.** Do not build a workaround for
any of them:

| What a document says | What is true now |
|---|---|
| `/drep/{id}` is a 20 s request with a 30 s cliff, or 503s outright | **1.8 s** (`ccaa2a1`, `ea90f48`) |
| `/drep/{id}/power` always 503s; the biggest stake holder cannot render | **0.02 s**, and 1.1 s for that holder |
| `/pages/dashboard.total_dreps` is 204 while `/dreps` is 294 | both **294** |
| `X-Attest-*` headers are sent but not CORS-exposed, so `headers.get()` is null | **exposed** |
| `/status.attestation` is `null`; this database has no projector | **published**, with `state`, `is_ready` and `policy_id` |
| every list route's `items` are typed `DisputeRow` in the committed Swagger | **13 per-element `Page_*` schemas**, asserted by `scripts/check_swagger.sh` |
| the published `GYAddress` description says bech32 | the description is corrected; **the hex requirement itself stands** |
| `actions_in_flight` is 11 | **7** — four of those actions had already expired |
| attestation and dispute pages have no data to build against | the projector's authentication gate was broken for both kinds (`5ae17bf`); run `scripts/smoke_attest_flow.sh` for a live corpus |

**These are still open**, and a screen that depends on one needs to know:

- `/votes` is 25–50 s from page 2 and 503s at its documented maximum page size. 3.2 M rows, 16 k pages.
- `/gov-actions?limit=50` is ~2.4 s, against 0.05–0.4 s for every other list route.
- The write API is Basic-auth only, so it cannot be called from a browser without a BFF.
- There is no way to ask "which profiles does this wallet own", and the policy id is published nowhere.
- A committee credential can be claimed but `/profiles/by-credential/` refuses to resolve it.
- No route exposes the oracle's parameters, so a dispute's deposit, its deadline and the arbiter's
  identity cannot be shown before asking for a signature.
- A script-credential claim needs a second signature and nothing collects or stores a partial one.

## Provenance

Written by three parallel agents, each confined to one half of the system, each required to cite
`file:line` or an endpoint for anything a reader might doubt and to mark what it could not verify.
They are **not** reviewed line by line by a human yet. Treat a specific claim the way you would treat
a measurement from a colleague: good enough to design from, worth re-running before you depend on it.
Every command needed to re-run one is in the document beside its number.
