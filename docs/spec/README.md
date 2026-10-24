# The specification the code cites

Everything in this repository that says "the spec", `§4.3`, `D-20` or `F-02` resolves here. Before
this directory existed those citations pointed at documents that were never committed, so the
protocol's requirements were not reviewable from the repository — finding `DC-43` of the 2026-10-22
audit.

| File | What it carries | What cites it |
|---|---|---|
| [`protocol.md`](protocol.md) | The functional specification, with its original section numbering preserved | `spec §2`, `§3 glossary`, `spec §4.1`, `spec §4.3`, `§6` — in the on-chain types, the validators, `Storage.hs`, `Core/Types.hs` and the tests |
| [`metrics.md`](metrics.md) | Per metric: the definition, the decision behind its denominator, and the measurement that settled it | the `spec` field of every entry in `resources/metric-formulas.json`, rendered as "Spec:" in `docs/metrics.md` and served by `/metrics/formulas` |
| [`decisions.md`](decisions.md) | Every `D-n` design decision and `F-n` inherited finding the code cites, one row each | the `(D-20)`, `(F-02)`-style tags in Haddocks, SQL comments and test names |

## The rules

1. **A citation must resolve.** A new `§N`, `D-n` or `F-n` in the code either has a row or a section
   here, or it is written out in words instead. An identifier that resolves to nothing is worse than
   no identifier: it looks like provenance.
2. **This is a statement of requirements, not a description of the code.** Where the two disagree,
   that is a finding to raise — not a line to edit here. `protocol.md` and `metrics.md` therefore keep
   the original decision and add a bracketed note naming what superseded it and why, with the
   measurement where there is one.
3. **The numbering in `protocol.md` is frozen.** It is the citation key. A new section is appended; an
   obsolete one is marked, never renumbered.
4. **What is NOT here**: the findings of the audit *of this repository* (`OF-`, `OC-`, `CS-`, `GV-`,
   `TD-`, `DC-`) live in [`docs/audit/`](../audit/), whose README §3 carries the status of each one.
   Decisions taken while building live in [`docs/adr/`](../adr/), each carrying the measurements
   behind it.
