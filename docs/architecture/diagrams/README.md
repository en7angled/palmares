# Rendered diagrams

Every file here is **generated** from a ```` ```mermaid ```` block in one of the three architecture documents in the parent directory. The Mermaid source in the Markdown is the source of truth; GitHub renders it inline. These SVGs exist so the diagrams can be opened, embedded in slides or shared without a Mermaid renderer.

Rendered 2026-10-23 from `main` @ `2bf5bde` with mermaid-cli 11.4.2, after reconciling all three
documents. All 26 blocks render; the one failure met on the way was a `;` inside a
`sequenceDiagram` note, which is the first pitfall listed under *Regenerating* below — added by an
edit that did not re-render, which is exactly what that instruction exists to prevent.

**Stale as of 2026-10-23.** `system-overview.md` was reconciled against `main` @ `2bf5bde` and six of
its Mermaid blocks changed, so these six SVGs are behind their source and need re-rendering:
`system-overview-02.svg`, `-03.svg`, `-05.svg`, `-06.svg`, `-07.svg`, `-10.svg`. The other four
`system-overview-*.svg` are current with their source; the on-chain documents were not reconciled in
that pass, so say nothing about theirs on this basis. The manifest below — file, type and section for
all 26 — is unchanged: no block was added, removed or renumbered.

## The three diagrams the owner asked for

| Diagram | File | Source |
|---|---|---|
| On-chain: validators, parameters, datums, tokens (ER view, part 1) | [`onchain-protocol-02.svg`](onchain-protocol-02.svg) | `onchain-protocol.md` §4 B1 |
| On-chain: redeemers (actions per validator) and enumerations (ER view, part 2) | [`onchain-protocol-03.svg`](onchain-protocol-03.svg) | `onchain-protocol.md` §4 B2 |
| On-chain: scripts, parameters and run-time reads (deployment order) | [`onchain-protocol-01.svg`](onchain-protocol-01.svg) | `onchain-protocol.md` §3 A |
| Application architecture: libraries and modules | [`system-overview-02.svg`](system-overview-02.svg) | `system-overview.md` §3.1 |
| Application architecture: executables, test suite, external systems | [`system-overview-03.svg`](system-overview-03.svg) | `system-overview.md` §3.2 |
| Deployment: compose profiles, volumes, ports, GHCR, SaaS | [`system-overview-07.svg`](system-overview-07.svg) | `system-overview.md` §9.2 |
| Deployment: target environments (preprod Pi cluster, mainnet host) | [`system-overview-08.svg`](system-overview-08.svg) | `system-overview.md` §9.3 |

## All diagrams

| File | Type | Document | Section |
|---|---|---|---|
| [`onchain-protocol-01.svg`](onchain-protocol-01.svg) | `flowchart LR` | `onchain-protocol.md` | 3. Diagram A — scripts, parameters and run-time reads |
| [`onchain-protocol-02.svg`](onchain-protocol-02.svg) | `classDiagram` | `onchain-protocol.md` | B1 — scripts, datums, tokens |
| [`onchain-protocol-03.svg`](onchain-protocol-03.svg) | `classDiagram` | `onchain-protocol.md` | B2 — redeemers and enumerations |
| [`onchain-flows-01.svg`](onchain-flows-01.svg) | `sequenceDiagram` | `onchain-flows.md` | 2. Bootstrap / deployment sequence |
| [`onchain-flows-02.svg`](onchain-flows-02.svg) | `flowchart LR` | `onchain-flows.md` | 3.3 (a) MintProfile — claim a profile |
| [`onchain-flows-03.svg`](onchain-flows-03.svg) | `flowchart LR` | `onchain-flows.md` | 3.5 (c) NewAttestation — issue |
| [`onchain-flows-04.svg`](onchain-flows-04.svg) | `flowchart LR` | `onchain-flows.md` | 3.6 (d) AcceptAttestation — countersign |
| [`onchain-flows-05.svg`](onchain-flows-05.svg) | `flowchart LR` | `onchain-flows.md` | 3.7 (e) OpenDispute |
| [`onchain-flows-06.svg`](onchain-flows-06.svg) | `flowchart LR` | `onchain-flows.md` | 3.8 (f) ResolveDispute |
| [`onchain-flows-07.svg`](onchain-flows-07.svg) | `stateDiagram-v2` | `onchain-flows.md` | 4.1 Profile |
| [`onchain-flows-08.svg`](onchain-flows-08.svg) | `stateDiagram-v2` | `onchain-flows.md` | 4.2 Attestation |
| [`onchain-flows-09.svg`](onchain-flows-09.svg) | `stateDiagram-v2` | `onchain-flows.md` | 4.3 Dispute |
| [`onchain-flows-10.svg`](onchain-flows-10.svg) | `stateDiagram-v2` | `onchain-flows.md` | 4.4 Oracle |
| [`onchain-flows-11.svg`](onchain-flows-11.svg) | `sequenceDiagram` | `onchain-flows.md` | 5.1 A DRep claims a profile and an organisation attests it |
| [`onchain-flows-12.svg`](onchain-flows-12.svg) | `sequenceDiagram` | `onchain-flows.md` | 5.2 A dispute from open to verdict |
| [`onchain-flows-13.svg`](onchain-flows-13.svg) | `sequenceDiagram` | `onchain-flows.md` | 5.3 Operator pauses, reprices the deposit, rotates the admin |
| [`system-overview-01.svg`](system-overview-01.svg) | `flowchart LR` | `system-overview.md` | 2. Context diagram |
| [`system-overview-02.svg`](system-overview-02.svg) | `flowchart TB` | `system-overview.md` | 3.1 Libraries |
| [`system-overview-03.svg`](system-overview-03.svg) | `flowchart TB` | `system-overview.md` | 3.2 Executables and the test suite |
| [`system-overview-04.svg`](system-overview-04.svg) | `flowchart LR` | `system-overview.md` | 4. Governance read path |
| [`system-overview-05.svg`](system-overview-05.svg) | `sequenceDiagram` | `system-overview.md` | 5. Attestation write path and read path |
| [`system-overview-06.svg`](system-overview-06.svg) | `flowchart TD` | `system-overview.md` | 5. Attestation write path and read path |
| [`system-overview-07.svg`](system-overview-07.svg) | `flowchart TB` | `system-overview.md` | 9.2 Deployment diagram |
| [`system-overview-08.svg`](system-overview-08.svg) | `flowchart LR` | `system-overview.md` | 9.3 Target environments (described, not provisioned here) |
| [`system-overview-09.svg`](system-overview-09.svg) | `flowchart LR` | `system-overview.md` | 9.4 Image layering |
| [`system-overview-10.svg`](system-overview-10.svg) | `flowchart LR` | `system-overview.md` | 9.5 CI pipeline (`.github/workflows/ci.yml`) |

## Regenerating

`render.py` extracts every Mermaid block of a Markdown file, renders it with `@mermaid-js/mermaid-cli` (via `npx`, Node ≥ 18) and reports the first parse error of any block that fails. Puppeteer needs a Chromium; the config below points it at a locally installed Google Chrome, which avoids the ~150 MB headless-shell download.

```bash
cat > /tmp/puppeteer-config.json <<'JSON'
{ "executablePath": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "headless": "shell" }
JSON
for d in onchain-protocol onchain-flows system-overview; do
  python3 -I docs/architecture/diagrams/render.py docs/architecture/$d.md /tmp/render/$d /tmp/puppeteer-config.json
  cp /tmp/render/$d/$d-*.svg docs/architecture/diagrams/
done
```

Two Mermaid pitfalls met while producing these: a `;` inside a `sequenceDiagram` note or message is a statement separator and breaks the block (the reported line number can be wrong), and `<…>` in a message is swallowed as HTML. Run the script before committing a diagram change; it exits non-zero when a block does not render.

