# Functional specification — a reputation and track-record registry for Cardano governance

**This is the document the code cites.** Haddocks and SQL comments in this repository reference it by
section number (`spec §2`, `§3 glossary`, `spec §4.3`, `§6`), and until it was committed those
citations resolved to nothing — a reviewer could not tell whether a validator implements the
requirement or the requirement was edited to fit the validator. That is finding `DC-43`.

**Provenance and status.** Translated from the owner's functional specification of **2026-10-19**
(written in Romanian, the owner's working language) and committed here in the repository's language.
The **section numbering is preserved exactly**, so every `§N` citation in the code resolves. Nothing
is added, removed or softened; where a later decision has overtaken a line, a bracketed
**`[Superseded: …]`** note names the ADR that did it and the original sentence stays. Requirements
are not edited to match the code — if the two disagree, that is a finding, and this file is what a
reviewer compares against.

Sections 1–8 and 10–13 are the specification as approved. Section 9 is the phase acceptance
criteria; F1 is the milestone this repository implements.

---

## 1. Objective and success criteria

**The problem.** Cardano's on-chain governance (CIP-1694) moves hundreds of millions of ADA while
the trust infrastructure is missing: Intersect researches proposers' track records by hand for the
budget process; delegators choose DReps almost blind (9.75 billion ADA parked on always-abstain);
the two Catalyst "DRep reputation" proposals delivered nothing functional; the existing tooling
(GovTool, Tempo.vote, drep.tools, 1694.io) shows *activity*, not *verifiable reputation*.

**The product.** Public, open-source infrastructure in three layers:

1. **A track-record explorer** (F1): governance data derived independently from the chain — the
   complete history of votes, delegations, participation and rationales for every DRep, SPO (on the
   actions they vote on) and CC member, plus governance-action pages and delegation discovery.
2. **A countersigned attestation layer** (preprod in F1, mainnet in F2): claimable on-chain profiles
   and two-step attestations (the issuer mints pending → the subject countersigns by accepting) for
   milestone delivery, audits, affiliations, mandates and endorsements — the central pattern
   inherited from the Belt System. **The audience, named by the owner (2026-10-20): Intersect, the
   committees (budget, product, and the CC in its off-chain role), communities and DReps, treasury
   vendors — and beyond them *any* vendor in the ecosystem, auditors included.** A vendor paid out of
   an organization's budget counts the same as one paid directly from the treasury; the only
   difference is whether there is an on-chain payment fact to anchor to (§2).
3. **A governance copilot** (F3): an MCP server and an AI assistant that answers from the indexed
   data (with citations), triages proposals, and builds delegation/vote transactions the user signs
   in their own wallet (CIP-95).

**Motivation (owner, 2026-10-19):** the project is built for the Cardano community — public, free,
with no dependence on any funding and no deadlines imposed by grant windows. A future proposal
(Catalyst/treasury) remains an optional sustainability path after launch, never a success criterion.

**Success criteria (measurable):**

- **S1.** A public explorer on **mainnet** with 100% of registered DReps and the complete vote and
  delegation history, verified by cross-sampling against independent sources (see §9.1).
- **S2.** Every displayed metric is **reproducible**: the formula is published and its inputs are
  queryable through the public API.
- **S3.** Used by the community: recurring organic use of the explorer after public launch (target
  order of magnitude: hundreds of unique visitors during voting windows) and public citations
  (forum, rationales, social) by community members.
- **S4.** Within 6 months of the mainnet launch (F2): ≥ 25 DReps with a claimed profile and ≥ 1
  issuer from the target classes (Intersect, a budget committee, a recognized community or an
  auditor) issuing countersigned delivery attestations — of which ≥ 1 anchored to a real treasury
  withdrawal, because the money ↔ delivery link is the proof that layer 2 adds something the chain
  alone does not say.
- **S5.** Zero opaque scores: no aggregate "rating" in v1 that is not algorithmically transparent
  (see Non-goals).

## 2. Concepts and domain

**Level-1 entities — derived from the chain, requiring no trust:**

- **Governance actor**: a DRep (key or script), an SPO (in its voter role), a Constitutional
  Committee member (cold/hot key), a delegating stake address.
- **Governance action**: the 7 Conway types (ParameterChange, HardForkInitiation,
  TreasuryWithdrawals, NoConfidence, UpdateCommittee, NewConstitution, InfoAction), with the
  lifecycle: proposed → voted → ratified/expired → enacted.
- **Vote**: (actor, action, Yes/No/Abstain, rationale anchor, tx, slot).
- **Vote delegation**: (stake address → DRep | AlwaysAbstain | AlwaysNoConfidence, tx, slot) plus
  per-epoch voting power.
- **DRep certificate**: registration / update / retirement, with a metadata anchor (CIP-119).
- **Metadata anchor**: (URL, hash) per CIP-100/108/119/136 — fetched, hash-verified, with the content
  and the validity verdict stored.
- **Outcome**: enacted/expired/dropped per action; executed treasury withdrawals.

**Level-2 entities — attested on chain through our own protocol:**

- **Profile** (CIP-68, reference + user token): an actor's claimed identity. The kinds, named
  explicitly by the owner (2026-10-20): **Person/DRep**; **Organization** (Intersect and its
  equivalents); **Committee** (budget, product, and the Constitutional Committee in its off-chain
  role); **Community** (a recognized group that delegates or endorses); **Vendor** — *any* supplier
  in the ecosystem, not only those paid directly from the treasury; **Auditor**. Claiming an on-chain
  identity (DRep ID, CC cold key, stake address) requires **proof that you can spend as that
  credential**: an extra signatory for key credentials, and for script credentials the consumption of
  a UTxO at that address in the claim transaction. It is a single rule precisely because most
  committees and organizations act through a multisig/script rather than a bare key — and authority
  inside the protocol is **possession of the user token**, which works identically for keys and for
  scripts (a list of signatures would not).
- **Attestation**: a statement issued by one profile about **another profile or about another
  attestation** — the auditor's case: "I audited the delivery attested here" — in two steps (mint
  pending → acceptance by the subject), permanent once accepted, with the kinds:
  `MilestoneDelivered` (a budget administrator attests delivery by a vendor), `AuditPassed`,
  `Affiliation` (organization ↔ member, with intervals), `RoleHeld` (an off-chain mandate: working
  group lead, committee chair — with intervals), `Endorsement`. Arbitrary metadata (key/value plus an
  IPFS anchor) as in Achievements.
- **A level-1 anchor on an attestation (optional)**: an attestation may reference the on-chain fact
  it comments on — a treasury withdrawal (`gov_action_id` plus the paid stake address, both already
  in `palmares.treasury_withdrawal`) or a governance action. This is what links **money to
  delivery**: the chain says "address X received N ADA under action G", and the countersigned
  attestation says "the paying committee confirms milestone 2, and the vendor agrees". It stays
  optional exactly because vendors paid out of an organization's budget rather than from the treasury
  have no on-chain payment fact — and they belong in the registry too.

**Boundary rule (owner, 2026-10-20):** we do not attest what the chain already proves. Constitutional
Committee membership, votes, delegations and treasury payments are **level 1** and are read from
db-sync. Level 2 covers exclusively what does not exist on chain: delivery, audit, affiliation,
mandate, endorsement.

- **Dispute**: a token referencing an attestation or a profile, with an IPFS-anchored reason and an
  anti-spam deposit; resolved by an arbitration mechanism (v1: the oracle admin; see the risks).
  Carries over the `DisputeValidator` idea from the July 2026 roadmap.
  **[Superseded: ADR 0005 — the arbiter is its own `Credential` field on the oracle, rotatable
  separately from the admin, so "the oracle admin" is the default and not the design.]**

**The trust model, in layers:** level 1 requires no trust in us (anyone can re-derive the data by
running open-source software from genesis: cardano-node + db-sync + this repository); level 2 requires
trust in the signers, not in the platform (both signatures are on chain); the AI layer (F3) always
cites its level-1/level-2 sources and issues no unfounded judgements of its own.

## 3. Operating modes and capability boundaries

- **Visitor (no wallet)**: the whole explorer, every read API, export. The primary audience.
- **Wallet user (from F1 on preprod; on mainnet from F2)**: claims a profile, issues/accepts
  attestations, delegates and votes from the copilot (F3) — always through build-on-server →
  unsigned CBOR → CIP-30/CIP-95 signing in the user's own wallet → submit. Never key custody.
- **Admin**: deploy, oracle (pause, parameters, key rotation — mandatory this time), v1 dispute
  arbitration.
- **Explicit boundaries**: the system does not vote on anyone's behalf, does not algorithmically
  recommend a "best" DRep, does not aggregate opaque scores, does not host discussion (we link to the
  forum/X), and does no KYC.

## 4. Functional requirements per component

### 4.1 The governance data layer: cardano-db-sync plus our own projections (decision revised 2026-10-19 — see the annex)

Kupo sees only UTxOs; certificates, votes and governance actions live in the transaction body and in
the ledger state. The 2026-10-19 technology analysis replaced the original plan ("our own Ogmios
follower plus ledger-state snapshots at epoch boundaries") with:

- **(call, revised 2026-10-19) The indexing substrate: cardano-db-sync 13.7.x** with the
  `only_governance` preset and the ledger **ENABLED** (mandatory — `ledger: disable` empties
  `drep_distr`). A sync from genesis natively populates everything F1 needs: `drep_distr` (voting
  power per DRep **per epoch**, for every past Conway epoch), `gov_action_proposal` with the
  ratified/enacted/expired/dropped epochs, `voting_procedure`, `delegation_vote`,
  `drep_registration`, `committee`, `treasury_withdrawal`. This removes the fragile epoch-boundary
  snapshot schema entirely — that would have meant re-implementing db-sync's central loop single
  handed, exactly the part in which contributors and auditors would have had the least confidence.
  Precedent: GovTool itself is an API over db-sync.
- **Our Haskell service becomes the projection and API layer** over db-sync's Postgres:
  deterministic, re-runnable transformations from db-sync's tables into our query tables (metrics,
  aggregates, composite pages). The independence claim is stated precisely: "anyone can re-derive the
  data by running open-source software — cardano-node + db-sync + this repository — from genesis".
- **The attestation protocol keeps its existing pipeline**: our validators produce UTxOs carrying our
  own policy's tokens, so the Belt System's Kupo chain-sync (cursor, idempotent raw log, ordered
  replay) is reused as is for the attestation projections — zero new technology on that path.
- **(call) Cross-check**: a periodic reconciliation job against **Koios**
  (`drep_voting_power_history`, `proposal_list`, `vote_list`, `drep_epoch_summary`) that alerts on
  divergence — Koios also runs on db-sync, so it is a free check in CI, not a source.
- **Metadata fetcher**: for each anchor — fetch with a timeout and a size limit, blake2b-256
  verification, content plus status stored (`valid | hash_mismatch | unreachable | oversized`);
  exponential retries; a permanent, re-derivable cache.
  **[Superseded: F1 check 7 — our own fetcher is cut. db-sync with `offchain_vote_data: enable`
  fetches and hash-verifies; we only classify the result in `palmares.anchor`.]**
- **An Ogmios mini-follower: cut for good** (all five design tracks, 2026-10-19 — on grounds of
  laziness: polling db-sync covers the activity feed, and a second data path would have to be
  maintained and reconciled).
- **Inherited requirements (mandatory fixes in the extracted code)**: timestamps are chain time
  (slot→UTCTime), never `insertedAt` (problem #5 of the October 2026 analysis); any datum-based
  projection verifies that the token named in the datum is present in the UTxO's value (problem #3,
  "projection poisoning") — this applies to the attestation projections (F1).

### 4.2 Query API (reuse: the query-api skeleton plus webapi-lib)

- **(call) Public, no Basic auth** (unlike the Belt System): it is public infrastructure; protection
  through a rate limit at the BFF and HTTP caching. Swagger auto-generated, as today.
- **DRep profile** (`/drep/{id}`): identity (verified CIP-119 metadata), status, full vote history
  with rationales, derived metrics (below), per-epoch voting power, delegators (count, churn), a
  unified timeline (the Belt System pattern).
- **v1 metrics — only reproducible facts, with the formula published**: participation rate (actions
  voted / actions it was eligible to vote on), rationale rate (votes with a valid anchor / total
  votes), tenure, delegator consistency (retention across epochs), vote latency (proposal→vote), the
  distribution of votes by action type. Explicitly NO composite score.
- **Governance actions** (`/gov-action/{id}`, `/gov-actions`): detail plus votes aggregated per group
  (DRep/SPO/CC) with thresholds and progress, CIP-108 metadata, the outcome, who proposed it (plus
  the proposer's history).
- **Delegation discovery** (`/dreps` with filters): active/inactive, participation, rationale rate,
  voting power, tenure, declared language/metadata; multiple sorts; limit/offset pagination (the
  existing conventions).
- **Committees and SPOs as voters**: minimal equivalent pages.
- **Vendors/treasury (from public data)**: a treasury withdrawal's page → beneficiary, amount, the
  parent action; in F2 it links to the claimed profile and to the milestone attestations.
- **Aggregates and composite pages**: a network dashboard (active DReps, delegated vs abstaining
  stake, actions in flight, participation per epoch), an activity feed with `since`, unified search,
  composite `/pages/*` per screen (the existing pattern — the frontend does not do N+1).
- **Export**: CSV/JSON on any list (a requirement from researchers and journalists).

### 4.3 The attestation layer (on chain; on preprod in F1, on mainnet in F2; heavy reuse from the engine)

- **CIP-68 profiles** with the user token as the bearer of authority (exactly as in the Belt System),
  kinds: Person/DRep, Organization, Committee, Community, Vendor, Auditor (see §2 — the audience is
  the Intersect/committees/communities/vendors/auditors ecosystem, not only DReps).
- **On-chain identity claim**: the single rule from §2 — "prove you can spend as that credential".
  For key credentials: an extra signatory in the claim transaction. For script credentials (the
  normal case for committees and multisig organizations): the claim transaction consumes a UTxO at
  that script's address, so the script's spending condition was satisfied. It applies identically to a
  DRep ID, a CC cold key and a stake address; the identity ↔ profile link becomes an on-chain fact.
  **This replaces the note "script DReps: a detail for the builder"** — it is not a detail, it is the
  majority case.
- **Two-step attestations**: a pending mint by the issuer (with the issuer's user token) → acceptance
  by the subject (with the subject's user token) → permanent, chained (a delivery lineage: milestone
  1 ← milestone 2 …). The subject may be a profile **or an attestation** (the audit of a delivery).
  Direct reuse of the Promotion/Achievement pattern, without a "belt" hierarchy — authority is not a
  rank but the verifiable identity of the issuer.
  **[Superseded: ADR 0006 — the lineage field is dropped. An attestation may still target another
  attestation (the auditor's case, which is what the requirement is for), but nothing carries a
  chain of predecessors.]**
- **An optional level-1 anchor**: the attestation's datum optionally carries the `(gov_action_id,
  stake_address)` of the treasury withdrawal or the action it concerns (§2). The validator does not
  check that the on-chain fact exists — it is a pointer, confronted at read time with
  `palmares.treasury_withdrawal`, and the API marks explicitly whether the pointer resolves.
  **(call)**: the alternative — on-chain verification through a reference input — would require the
  withdrawal to be an addressable UTxO, which it is not, so read-time verification it is.
- **Disputes**: a dispute token with a deposit, a reference to the attestation concerned, an anchored
  reason; the verdict (v1) from the oracle admin, displayed beside the attestation without hiding it.
- **Oracle**: pause, min-UTxO, deposit parameters plus **admin key rotation** (the fix for problem #2)
  and, desirably, a native multisig admin (M-of-N; the decision is the builder's after estimating
  ExUnits — respecting the principle "no ExUnits for non-exploitable defense").
  **[Superseded: ADR 0005 — `opAdmin` is a `Credential`, so a native script (multisig) admin is
  expressible without any M-of-N logic on chain and without any ExUnits cost.]**
- **NO protocol fees as a business model** (the JPG Store lesson); anti-spam deposits are returned.
  Funding is grants/budget, not per-transaction taxation.
- **Validators**: PlutusTx/Plinth, the existing "on-chain minimal, mirror-and-pin" philosophy plus
  the rules in `src/lib/onchain-lib/CLAUDE.md`; a property test pinning the off-chain rule ≡ the
  on-chain rule, as today. The fixes for problem #1 (wrong fee selector) and #4 (dates unbound from
  the validity range) are handled by design: any date carried in a datum is validated against the
  transaction's validity interval.
- **Rollout**: preprod first, mainnet after ≥ 1 month of soak plus an external review of the
  validators.

### 4.4 MCP server plus copilot (F3; reuse: mcp-server-lib plus agent-service)

- **Read tools** over the whole query API (the equivalents of the existing fifteen, plus
  `get_drep_track_record`, `get_gov_action_summary`, `compare_dreps`, `get_delegation_options`).
- **Write tools** (gated by env, as today): `build_delegate_tx`, `build_vote_tx` (for DReps, through
  CIP-95), `build_claim_profile_tx`, `build_attestation_tx`, `build_accept_attestation_tx` — all
  returning `{cbor_hex}` for wallet signing; the chat signing bridge (a Redis checkpoint plus a
  `tx_action` SSE) is reused as is. Verified 2026-10-19: Atlas 0.14.1 (the pinned version) already
  supports DRep certificates, vote delegation and `VotingProcedures` in `GYTxSkeleton`, so these
  tools are built with the existing TxBuilding stack, with no new SDK work.
- **(decision deferred to the F3 plan, to be brought to the owner then)**: how the copilot is exposed
  (anonymous vs wallet-gated vs a per-IP quota — a public LLM endpoint on a free site is a real cost
  and abuse surface) and the inference provider (agent-service already allows switching the OpenAI
  base URL to vLLM/on-prem; for a public governance tool the provider choice is a trust decision, not
  only a cost one).
- **Copilot**: (a) proposal summaries STRICTLY with quotations from on-chain metadata plus links
  (political content ⇒ every statement traceable to its source); (b) "what changed since your last
  vote"; (c) triage: the proposals the connected DRep has not voted on yet, ordered by deadline;
  (d) Q&A over the track record. Guard rails inherited from agent-service (anti-injection
  sanitization, reflection, limits) plus a **policy gate** on the write tools (inspired by defi-bot):
  no vote transaction is built without explicit confirmation of the vote option in the conversation.
- **MCP resources**: a short CIP-1694 guide, the glossary, the metric formulas (the equivalent of
  `bjj://rules/*`).

### 4.5 Frontend (TypeScript + React + Mesh; decision revised 2026-10-19 — see the annex)

- **(call, revised 2026-10-19)** A new frontend in **TypeScript + React** (Vite), with **Mesh 1.9.x**
  for wallet connect and **CIP-95** (required by governance actions; supported today by
  Eternl/Lace/Typhon). Rationale: the project is for the community, and the contributor pool is
  React/TS — GovTool and every peer tool is React/TS; Mesh replaces our PureScript wallet libraries
  for free, including the CIP-95 part we would otherwise write ourselves. The **patterns** are reused,
  not the PureScript code: composite pages per screen, RemoteData states with skeleton plus retry,
  filters/pagination/parameters in the URL, the chat→signing bridge, the four-step wizard. The
  PureScript libraries stay with the Belt System.
- **Explorer-first**, the same patterns: Hub, Dashboard, a DRep list with filters, pagination and URL
  params, a DRep page with a unified timeline, action pages, the **delegation/attestation graph**
  (cytoscape.js, the same engine as in BJJ), ⌘K search, an activity feed, protocol status.
- **Claim and attest wizard**: the Action Composer pattern (Select → Fill → Review → Track),
  re-implemented in React, with new forms.
- **Verification**: VerificationChip/Panel parameterized on `credentialKind` (the existing pattern),
  explorer links plus tx proof; an embeddable "Verified track record" widget for DReps' own sites
  (backlog item E12 from BJJ finds its real audience here).
- **Copilot drawer** (F3): the Chatbot pattern plus the same signing bridge (checkpoint plus
  `tx_action`), re-implemented; and additionally, beyond BJJ: a signing card with a **decoded summary
  of the transaction** (the fix for the blind-signing risk flagged in the frontend analysis).
- **Inherited requirements (fixes)**: the network is configurable at build time (not hardcoded), no
  provider keys in the bundle, a BFF with a rate limit.

### 4.6 Admin and operations

- An admin CLI on the existing model: deploy-reference-scripts, write-blueprint (CIP-57), oracle ops
  (plus `rotate-admin`), dispute arbitration.
- Deployment: Docker images plus k8s/Flux on the minirack (the existing topology), docker-compose for
  dev/audit; everything self-hostable by third parties (a credibility criterion).

## 5. Data flow

```
Cardano node (preprod in F1, mainnet from F2) ──▶ cardano-db-sync (only_governance, ledger ON) ──▶ db-sync Postgres
                                                                        │
                                    Koios (periodic cross-check, in CI) ──┤
                                                                        ▼
        Projections + metrics (Haskell service; deterministic, re-runnable) ◀── Metadata fetcher (CIP-100/108/119 anchors)
                                                                        │
Attestation validators ──▶ Kupo (the Belt System pattern: raw log + replay) ─┤
                                                                        ▼
                                      Query API (public, rate-limited) ──▶ Explorer frontend / Export / third parties
                                                                        └──▶ MCP server ──▶ Copilot (citations mandatory)
Attestations (F1 preprod → F2 mainnet): Interaction API ──build──▶ unsigned CBOR ──▶ user wallet (CIP-30/95) ──▶ submit ──▶ chain
```

## 6. Data model (key projections)

- `drep` (id, credential kind, status, anchor + verdict, registration/retirement slot),
  `drep_update_log`
- `vote` (actor_type, actor_id, gov_action_id, verdict, anchor + verdict, tx, slot)
- `gov_action` (id, kind, proposer (reward account), deposit, anchor, state, key epochs, outcome)
- `vote_delegation` (stake_addr, target, tx, slot), `drep_epoch_power` (drep, epoch, lovelace,
  delegator count)
- `committee_member`, `committee_vote_auth`, `treasury_withdrawal`
- `anchor_content` (url, hash, status, content, fetched_at)
- Attestations (F1): `profile_projection`, `attestation_projection`, `dispute_projection` (adapted
  from the existing ones, with tx_hash/slot/output_index as today)
- Bookkeeping (the attestation pipeline only): `chain_cursor`, `raw_event_log`, `schema_version` —
  mechanically identical to the Belt System's; the governance layer takes its consistency from
  db-sync, and our projections over it are deterministic, re-runnable transformations.

**[Note: the governance half of this list is implemented as SQL views over db-sync rather than as
tables — decision `D-1`. The names above are therefore `palmares.*` views; only the attestation
pipeline owns tables.]**

## 7. Non-functional requirements

- **Fully open source, Apache-2.0 (call)**, a public repository from the first commit; no secrets in
  the history (the Maestro token lesson).
- **Reproducibility**: anyone can run the stack and obtain the same figures; the metric formulas are
  documented in the repository and exposed as an MCP resource.
- **(call) The write path (build-tx) uses a commercial provider** (Maestro, exactly as in the Belt
  System today — the Atlas↔Ogmios v7 incompatibility persists), with the key injected from the
  environment, never in the repository. "Self-hostable" is promised precisely: the read path (indexer
  + API + UI) is 100% autonomous on your own node; the write path requires your own provider key (a
  free tier is enough for small volumes). Restoring Atlas↔Ogmios v7 compatibility is recorded as a
  future, non-blocking workstream (an ADR at F0). To evaluate at planning time: Atlas's **local-node**
  or **db-sync** providers — db-sync runs anyway (§4.1), so the Maestro dependency could disappear
  entirely.
  **[Superseded: ADR 0004 — Maestro withdrew its Cardano API in 2026 and the hostname no longer
  resolves. The write path is Atlas's `GYNodeKupo` (socket + Kupo), measured: it deployed F1 and needs
  no account and no secret. The last sentence of the requirement is what happened.]**
- **Rollback correctness**: identical to today's guarantees (replay from the raw log); displayed time
  is chain time.
- **Availability**: the public explorer is served through a BFF with caching; the indexer may lag by
  at most N slots before `/ready` fails (the existing pattern).
- **No personal data** beyond what is already public on chain or in the anchors; the metadata caches
  are re-derivable and deleted on request only if the source has disappeared too (to be detailed at
  planning time).
- **Haskell/devx Nix** as today; CI with `cabal build all` plus `cabal test` plus parity tests on
  fixtures.

## 8. Assumptions and dependencies

- F1 runs on **preprod** (owner's decision, 2026-10-19): it needs a preprod node plus
  **cardano-db-sync** (`only_governance`, ledger ON) in the minirack — it fits on a Pi (≈16 GB
  Postgres plus ≈12 GB node DB, ~3.5 GB RAM for db-sync with the classic ledger backend); the node is
  bootstrapped through Mithril (a procedure rehearsed in July 2026). **Mainnet (F2) has a real
  hardware threshold**: mainnet db-sync needs an x86_64 machine with 48–64 GB RAM and ~1 TB NVMe (the
  experimental LSM backend is documented as risky on a Raspberry Pi) — we do not promise mainnet on
  the minirack; a dedicated machine is budgeted at F2.
- **Versions for the new repository** (fixed after fact-checking, 2026-10-19): cardano-node 11.1.2;
  **cardano-db-sync 13.7.1.0** — the arm64 image `ghcr.io/blinklabs-io/cardano-db-sync:13.7.1.0`
  pinned by digest (NOT 13.7.2.1: no arm64 build exists for it); Postgres 17; GHC 9.6.6 (a pin imposed
  by plutus-tx-plugin); Atlas 0.14.1; Plutus/Plinth 1.7x; FE: current React + Vite, Mesh 1.9.x. Image
  registry: **GHCR**, `ghcr.io/<owner>/palmares-<svc>`. No pin bumps during the extraction.
- The existing Postgres and k8s/Flux pipeline.
- **Libraries extracted from Decentralized-Belt-System** (the new repository consumes them as
  local/sub-tree libraries; the exact mechanism at planning time): `webapi-lib` in full; the
  `Storage`/raw-log/replay mechanism; the `TxBuilding` skeleton (Context, Skeletons, Transactions, the
  oracle/fee/validity part of Operations); the MCP plumbing; the query-api skeleton (dual backend,
  pagination, pages); from the frontend: the wallet libraries (already separate repositories), the
  explorer shell (RemoteData, filters, pagination, ⌘K, feed), the BFF, the agent service.
- **The inherited fixes** are made in the extracted code before the first launch: #1 the fee selector
  (pattern), #2 admin rotation, #3 the token check at projection time, #4 dates bound to the validity
  range, #5 chain time.
- **Development tooling**: the `cardano-dev-skills` plugin (already active) plus the 13 skills
  vendored today from defi-bot into `.claude/skills/` — copied into the new repository at bootstrap.
- The Belt System **freezes** on preview as a demo and historical vertical; it is no longer actively
  developed (owner's decision, 2026-10-19).

## 9. Phase acceptance criteria

### F0 — Bootstrap (weeks, not months)

- A new repository (name chosen by the owner), Apache-2.0, green CI, the extracted libraries compile,
  fixes #1–#5 applied in the extracted code and tested.
- Exit: `cabal build all` plus green tests on the empty skeleton, plus ADR
  `0001-governance-data-substrate.md` fixing the data source (cardano-db-sync, preset
  `only_governance`, ledger ON) with the measurements from Experiment A, plus ADR
  `0002-write-path-provider.md` for the write path.

### F1 — The complete product on PREPROD (the implementation goal, fixed by the owner 2026-10-19; widened the same day at the owner's request to include the on-chain attestations and the complete UI)

**GOAL**: on **preprod**, the whole product runs end to end: the governance data layer
(cardano-db-sync `only_governance` → `palmares.*` views plus a single matview) plus the on-chain
attestation protocol (claimable profiles, countersigned attestations, disputes) plus a public Query
API plus a **complete UI** — with correctness demonstrated through external parity, idempotence under
re-sync and emulator tests on the validators, and with the user flow demonstrable from claim through
public verification. Mainnet (F2) then requires no code changes to the indexer/API/UI, only config,
resources and a redeploy of the validators after review.

The internal build order stays: data layer → on-chain protocol → UI — but the phase is "done" only
with every check passed.

**A. The governance data layer** (each step is "done" only with its verification passed):

1. A preprod node plus cardano-db-sync (`preset: only_governance`, `ledger: enable`,
   `shelley: enable: true`, `offchain_vote_data: enable`) synced **from genesis** — and "from genesis"
   is a **correctness** requirement, not merely a completeness one: db-sync issue #1975 documents two
   identical instances differing by ~740× on one DRep's voting power, and the 13.6.0.4 Known Issue
   names preprod explicitly ("pre-upgrade `drep_distribution` values are not well defined"); the
   documented remedy is exactly a recomputation from genesis with fresh ledger-state files. A db-sync
   restored from a snapshot would inherit ill-defined values in precisely the column the whole product
   rests on → verify: db-sync at tip, `lag_seconds` from `/status` < 120 s sustained over a soak
   window; `drep_distr` populated for every Conway epoch on preprod; `stake_deregistration` and
   `pool_update` non-empty (proof that the `shelley` flag took effect — otherwise a full re-sync is
   the price).
2. The `palmares.*` views cover everything: DReps (reg/update/retire), vote delegations, committees
   (with hot→cold resolution), gov actions with the complete lifecycle
   (ratified/enacted/expired/dropped), votes (all three roles), withdrawals → verify: count > 0 per
   entity kind plus samples checked by hand against a public preprod explorer.
3. Determinism (restated 2026-10-19 — the governance layer is views, not a projection service, so
   determinism holds by construction): running the metric catalog's SQL twice over the same db-sync
   gives identical output → verify: a hash over the output, identical between runs. **No determinism
   harness is built for a `SELECT`.**
4. Rollback safety (restated): rollback is handled by db-sync itself and the views reflect it
   automatically → verify: for the attestation pipeline (the only one with state of its own), the
   existing replay test (the chain-sync pattern) adapted and green.
5. Per-epoch voting power exposed from `drep_distr` through `palmares.drep_epoch_power` (with
   `target_kind`, including the always-abstain / always-no-confidence pseudo-DReps) → verify: the sum
   of the powers ≈ the total delegated reported by Koios preprod at the same epoch (with a documented
   tolerance).
6. **External parity**: over ≥ 20 preprod DReps and ≥ 10 gov actions, the votes and delegations match
   Koios preprod → verify: a reconciliation script with 0 unexplained divergences (explained
   divergences are documented).
7. Metadata anchors: **our own fetcher is cut** — db-sync (`offchain_vote_data: enable`) fetches and
   hash-verifies by itself; we only classify the result → verify: every anchor has a verdict from
   `palmares.anchor` (`valid | invalid_schema | hash_mismatch | oversized | unreachable | inline |
   not_fetched`), with a golden test on the exact error strings; the verdict is visible in the API.

**B. The on-chain attestation protocol (preprod):**

8. PlutusTx validators (CIP-68 profiles with an on-chain identity claim for **both** credential kinds
   — key and script —, two-phase attestations whose subject is a profile or an attestation, disputes,
   an oracle with admin rotation) → verify: an emulator suite on the `mkTestFor` pattern with coverage
   of the negative paths, including one successful script-credential claim and one refused (the
   consumed UTxO is not from the claimed address), an on-chain ≡ off-chain property test, a generated
   CIP-57 blueprint.
9. The inherited fixes applied in the extracted code (#1 the fee selector, #2 admin rotation, #3 the
   token check at projection time, #4 dates bound to the validity range, #5 chain time) → verify: a
   dedicated test per fix, which fails on the old behaviour.
10. Deployment on preprod: reference scripts plus the oracle → verify: the deploy command produces the
    validators config, `/ready` on interaction-api is green.
11. Complete flows through interaction-api: a profile claim on both credential paths (key: an extra
    signature; script: consuming a UTxO from the claimed address) → issuing an attestation (pending),
    with and without a treasury anchor → countersignature (accept); a dispute opened → resolved →
    verify: end-to-end smoke scripts on preprod (the populate/test_*.sh pattern), and the resulting
    projections appear correctly in query-api, with tx proof; the anchored attestation shows the
    corresponding treasury withdrawal from `palmares.treasury_withdrawal` in the API, and one with an
    unresolvable anchor is marked as such rather than hidden.

**C. Query API plus the complete UI (preprod):**

12. A public Query API (no Basic auth, rate-limited) with Swagger: `/dreps` (filters plus pagination),
    `/drep/{id}` (full history plus metrics with published formulas plus attestations),
    `/gov-actions`, `/gov-action/{id}`, profiles/attestations/disputes, `/activity`, search, dashboard
    aggregates, CSV/JSON export → verify: handler tests plus a smoke script against the preprod stack.
13. Every explorer page: hub, dashboard, a DRep list with filters/pagination/URL parameters, a complete
    DRep page (unified timeline plus metrics plus delegators plus attestations), gov action pages, the
    delegation/attestation graph (Cytoscape), ⌘K search, an activity feed, export → verify: Playwright
    on every route plus green FE unit tests.
14. The wallet flows in the UI: the claim and attest wizard (the Action Composer pattern, in React plus
    Mesh/CIP-95), accept/dispute, a signing card with a **decoded transaction summary** (no blind
    signing) → verify: Playwright e2e on preprod with a test wallet — a transaction built, signed,
    confirmed and reflected in the UI.
15. Public verification: VerificationChip/Panel on every attested entity, tx-proof links, the embeddable
    "verified" widget → verify: the widget renders correctly in an external test page.
16. A reproducible deployment of the whole stack (BE + FE + BFF): docker-compose for dev/audit plus a
    preprod k8s overlay on the minirack → verify: Flux ready=True, `/ready` green on every service,
    everything GitOps-clean.

Interpretation (call, open to challenge by the owner): "complete UI" = everything to do with the
explorer plus attestations (the list above); the AI copilot and the MCP server stay in F3 and are not
part of this goal.

F1 non-goals: no mainnet, no MCP/copilot.

### F2 — Promotion to mainnet

- A mainnet node plus db-sync on a dedicated x86_64 machine, 48–64 GB RAM, ~1 TB NVMe ((call) exact
  sizing at planning time; Mithril for the bootstrap) — explicitly NOT on the minirack; indexer/API/UI:
  the same code, new config.
- Re-running checks 2–7 on mainnet, with a larger sample (≥ 30 DReps, ≥ 20 actions) and an additional
  cross-check against GovTool; a human spot check: three known DReps' track records confirmed by
  somebody who follows them.
- The attestation validators: redeployed on mainnet only after ≥ 1 month of soak on preprod plus an
  external review (the requirement from §4.3).
- A live public explorer (the complete list from check 13) plus a documented API.
- A public launch to the community: an announcement on the Cardano forum plus social, with the
  methodology and the API documented; the feedback collected becomes the F3 backlog (S3).

### F3 — Copilot

- MCP read tools with 1:1 parity against the API (the parity tests exist as a pattern); write tools
  gated.
- The copilot answers 20 benchmark questions with correct citations (the eval set is in the
  repository); zero transactions built without explicit confirmation of intent; the decoded tx summary
  appears in the signing card.

## 10. Non-goals (explicitly outside the system)

- Composite or opaque reputation scores, or "best DRep" rankings in v1 (facts plus public formulas
  only).
- Automatic voting or delegation; key custody; server-side signing.
- A forum or discussions, content moderation, KYC.
- A platform DAO of our own; tokenomics; protocol fees as revenue.
- Midnight, horizontal SSI, an AI agent registry (rejected in the 2026-10-19 pivot analysis).
- Catalyst as an indexed domain in v1 (on-chain Conway governance only; Catalyst has its own APIs and
  may come later as an extension).

## 11. Sources of inspiration (explicitly requested by the owner)

**In the Cardano ecosystem** — to be studied before the F1 plan, in this order:

- **GovTool** (gov.tools; maintenance taken over by Sireto, open-source) — the minimum functional
  reference; what NOT to repeat: the absence of an aggregated per-DRep history.
- **Tempo.vote**, **drep.tools**, **1694.io** (Lido Nation), the **Cexplorer**/**AdaStat** governance
  hubs — what they show, what is missing (attested reputation, reproducible metrics, a public API).
- **Intersect's manual proposer track-record process** (forum, 2026) — the exact list of questions
  they ask themselves is our metrics backlog.
- **Koios** (governance endpoints) and **cardano-db-sync** (the governance table schema) — as a
  reference for data completeness; **CIP-1694, CIP-95, CIP-100/108/119/136** — the data contracts.
- **Andamio** — the only live credential protocol on Cardano; its access-token model is worth studying.

**Outside the ecosystem:**

- **Karma (karmahq.xyz)** — delegate reputation for EVM DAOs; the closest product to what we are
  building; worth studying for which metrics it shows and how it handles gaming.
- **Tally** and **Agora** (Optimism) — delegate pages and delegation-discovery UX; **Boardroom** —
  multi-DAO aggregation; **DeepDAO** — analytics; **L2BEAT** — the benchmark for honesty in presenting
  data (risk badges, a public methodology); **Snapshot** — rationale anchoring.
- **ERC-8004 post-mortems** (arXiv 2026) — why reputation registries without countersignature and
  without skin in the game fail (Sybil); this justifies our two-phase design.

**From our own repositories:**

- `Decentralized-Belt-System` — two-phase consent, lineage, the eligibility engine, mirror-and-pin,
  idempotent replay.
- `defi-bot` — the format of this specification, ADR discipline, the **policy gate** pattern on
  money-moving actions, the hardening of vendored skills.
- `bjj-frontend` — the explorer shell, the chat→signing bridge, the Action Composer.

## 12. Minimal glossary

**DRep** = a delegated vote representative (CIP-1694); **CC** = the Constitutional Committee;
**gov action** = an on-chain proposal; **anchor** = a (URL, hash) pair pointing at off-chain metadata;
**attestation** = an on-chain statement countersigned by its subject; **claim** = binding a governance
credential to a CIP-68 profile; **Chang** = the hard fork that activated Conway and governance.

## 13. Annex: the technology analysis (2026-10-19) — a verdict per layer

Up-to-date research done at the owner's request ("other, better-suited technologies? library
upgrades?"), with the verdict applied in the sections above:

| Layer | Verdict | The choice | Why (one line) | Migration cost |
|---|---|---|---|---|
| Governance indexing | **Replaced** | cardano-db-sync **13.7.1.0** (arm64), preset `only_governance`, ledger ON. **Yaci-Store: rejected as the substrate** (re-evaluated 2026-10-19) — its `drep_dist` depends on the UTxO store, so it is *harder*, not easier; no ENACTED/DROPPED in the lifecycle; no anchor fetch/verification; its partitioning would break our views. It remains only as a possible cross-check (a second independent derivation). | `drep_distr` per epoch plus the gov-action lifecycle come natively, from genesis; our own follower would have re-implemented db-sync's central loop single handed | M |
| On-chain language | **Kept** | PlutusTx/Plinth (Plutus 1.72; the team moved to Midgard Labs, which also maintains Aiken/Plutarch) | 3k tested lines plus on≡off property pinning plus the CLB harness beat a rewrite in Aiken; CIP-57 blueprints serve non-Haskell contributors | S |
| Off-chain Haskell | **Kept** | Atlas 0.14.1 (already the latest release; gov tx building exists since 0.8.0) | No better-maintained Haskell alternative; Ogmios v7 remains incompatible — a Maestro provider or (to be evaluated) local-node/db-sync | S |
| Frontend | **Replaced** | TypeScript + React (Vite) + Mesh 1.9 (CIP-95) | A community project ⇒ the React/TS contributor pool (GovTool and every peer tool are React/TS); Mesh gives CIP-95 for free | L |
| Node/infra | **Upgrade** | node 11.1.2, db-sync 13.7.2.1, Mithril, Postgres 17 | Routine pins; preprod fits on the minirack, mainnet does not (see the risks) | S |
| Agent (F3) | **Kept** | Python + LangChain 1.x, LangGraph at F3 | The least-built phase; model agnosticism remains the goal | S |

**Risks recorded honestly:**

- **The mainnet hardware threshold (F2)**: mainnet db-sync = 48–64 GB RAM x86_64 plus ~1 TB NVMe (the
  node DB alone ≈ 203 GB); the LSM backend that would reduce RAM is documented as unstable on a
  Raspberry Pi. We do not promise mainnet on the minirack.
- **Atlas is a single-vendor dependency** (GeniusYield; 5 months without a release, ~45 open issues):
  we keep the escape hatch "build the handful of transaction kinds directly on cardano-api" if it
  stagnates.
- **Maintenance of Cardano's core components moved in 2026** (Plutus→Midgard Labs, Mithril→Teragone,
  the ledger→other teams, through Intersect): continuity is promised, not proven — one more reason for
  the existing doctrine "simple validators, logic off chain".
- **To avoid (dead or unsuitable)**: Carp (no activity in 2026), cardano-graphql (legacy), Kupo for
  governance (it does not see certificates or votes — it stays only on the attestation contracts),
  Dolos (promising, but it serves current state rather than a historical SQL store; worth watching).
- **The GovTool lesson**: community funding of governance tooling is precarious — we design so that
  one person with one db-sync machine can credibly run the whole registry (the `only_governance`
  preset makes that realistic).

## What is left to the builder

The exact library-extraction mechanism (sub-tree vs copying vs cabal local packages); the exact
schema of the projections over db-sync's tables; the final Postgres schema; the claim for script
DReps; the dispute parameters (deposit, window); mainnet node sizing; the choice of name (owner).
Resolved 2026-10-19 (owner): there is no funding window with a fixed date — the project is built for
the community; a future funding proposal remains optional and subsequent to launch.
