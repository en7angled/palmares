# Onchain Library Rules

PlutusTx on-chain code. No off-chain imports (no Aeson, Servant, Swagger). PlutusTx types and instances only.

## Plutus Coding Style

- **INLINEABLE**: `{-# INLINEABLE fn #-}` **before** type signature for every cross-module function.
- **Trace messages**: Short unique codes: `traceIfFalse "M0" condition -- Description (M0)`. Same for `traceError`.
- **Validators**: Keep lambdas under ~80 lines. Extract per-redeemer logic into named helpers.
- **Output checks**: Use output-index checks only (no O(n) search). Redeemers carry expected output index.
  - **Min-value** (`checkTxOutAtIndexWithDatumMinValueAndAddress`): the only shape. For continuing outputs
    (value ≥ spent value) and newly created state outputs (value ≥ minLv + NFT). Balancer may add lovelace.
  - There is no exact-value variant. One existed, documented here as "only when value is not modified by
    the balancer (rare)", and it had zero callers for the reason that sentence hints at: every state
    output in this protocol carries datum-size-dependent min-ADA, so no call site can name the value
    exactly. Both halves of the pair were deleted rather than left as an option nothing can take.
- **Validator structure**: `mkUntypedLambda` wraps typed lambda. Pattern-match
  `ScriptContext txInfo (Redeemer bredeemer) scriptInfo`; `SpendingScript spendingTxOutRef mdatum` for spending.
- **Constants**: Named constants from `Palmares.Onchain.Utils`. No magic numbers.
- **Plutus version**: Plutus V3 with `ghc-options: -fplugin-opt PlutusTx.Plugin:target-version=1.1.0`.

## Project Onchain Concepts

- **Types**: New types in `Protocol/Types.hs`. Use `makeIsDataSchemaIndexed` with **stable** indices. Never
  reorder constructors. Add `HasBlueprintDefinition` for CIP-57.
- **ID derivation**: `Utils.nameFromTxOutRef` (`blake2b_224` of the seed `TxOutRef`) prefixed by
  `CIP68.generateRefAndUserTN` for a PROFILE (CIP-67 labels 100/222), `generateAttestationTN` for an
  attestation (private-use label 1) and `generateDisputeTN` for a dispute (label 2) — ADR 0006 gave
  each kind its own label so `Mg`, `Md4` and `Mr` can tell one id from another. This is the only derivation
  path. `Protocol/Id.hs` used to hold a second one with zero callers and has been deleted; if you are
  reading an older commit, that module is not where a new derivation goes.
- **Datum optimization**: Derive IDs from datum fields, don't store derivable IDs. Reduces datum size and min-ADA.
- **ProtocolParams**: Carried in datums for unparameterized validators. Only MintingPolicy is parameterized.
- **Address resolution**: ProfilesValidator, AttestationsValidator and DisputesValidator are
  **unparameterized**, and none of them resolves a sibling validator's address at all — the only field
  any of them reads out of `protocolParams` is `oracleToken`. The three script hashes are read by the
  MintingPolicy, where they are a compile-time **parameter**, not a datum. Do not add validator hashes
  as validator parameters, and do not write that a validator gets an address from a datum: this line
  said so, and an audit (OC-08) found no code behind it.
- **Multiple datum kinds**: Use wrapper sum type. List which redeemers each kind accepts; reject incompatible
  with `traceError`.
- **Output layout**: The order of outputs in the transaction is determined by the off-chain skeleton
  `mconcat`. Redeemer parameters (e.g. `profileOutputIdx`) must refer to that order. Document the output
  layout in a comment when adding or changing a redeemer.

### Minting Policy

- New token kind → new redeemer in `MintingPolicy.hs`.
- Validate **exact mint**: `mintValueMinted == expectedValue`. Never allow extra token names.
- Oracle UTxO as **reference input** in every minting tx. Check `opPaused` and `checkFee`.
- Min lovelace from oracle (`opMinUTxOValue`) only, not fixed constants.
- One-off tokens: require spending a **seed TxOutRef**, derive token name from it.
- Validate referenced AssetClasses with the TYPED predicate for the kind you mean: `isProfileId` or
  `isAttestationId` from `Palmares.Onchain.CIP68` — symbol AND that kind's CIP-67 label.
  `isProtocolRefToken` is the untyped ancestor and now means only "is a profile id"; it is kept
  because `isRefTokenName` is still what `P7` asks of a profile datum. There is no `isDisputeId`: it
  had no caller, because no redeemer field anywhere names an id of the DISPUTE class — a dispute
  points at things and nothing points at a dispute. Write it back if that changes;
  `isDisputeTokenName` (the half `D8` and `Ingestion` use) is still there.
  A symbol-only check is what `isProtocolRefToken` closed a hole over: a profile's USER token
  satisfies the symbol alone, and `UnitTests.MintInputs` pins that. `Utils.hasCurrencySymbol` was
  that check, this line used to prescribe it, and it is now deleted rather than left as an invitation.
- **Authorization**: every redeemer names the credential it requires, and the requirement is token
  possession, not a signature list — that is what makes an organization or committee acting through a
  script a first-class issuer. Use `deriveUserFromRefAC` from `Palmares.Onchain.CIP68`: profile creation
  requires the seed TxOutRef; issuing an attestation requires the **issuer's** User NFT; accepting one
  requires the **subject's** User NFT; opening a dispute requires the disputer's User NFT plus the deposit.
- **CurrencySymbol**: In the minting policy, pattern-match on `MintingScript mintingPolicyCurrencySymbol`
  and pass to handlers.
- **Fee check**: `feeFor :: MintAction -> FeeConfig -> Integer` in `Palmares.Onchain.Protocol.Lookup` is the
  only place a `FeeConfig` fee AMOUNT is selected (`checkFee` names `fcFeeAddress`, and the admin CLI
  names all three — `scripts/check_vocabulary.sh` enforces exactly that boundary); `checkFee :: OracleParams -> MintAction -> [TxOut] -> Bool`
  takes the action, never a selector. The Belt System's selector-passing signature is exactly how its
  interval fee ended up charging the wrong field — one function, one naming site, no selectors.

### Validators

- **Cleanup redeemer**: All state validators have it. Anyone can spend if the datum is absent, unparseable,
  OR names a state NFT the UTxO's own value does not hold (`Utils.isUnbackedDatum`); must
  fail if datum valid.
- **Business logic**: In `Protocol.Types` helpers and the per-validator helper functions. Validators call
  these; no complex logic in the validator lambda.
- **CIP68Datum**: State with metadata uses `CIP68Datum OnchainProfile` etc. Use `extra` for inner datum.
- **Oracle validator**: Unparameterized; the admin *credential* must prove control (`checkCredentialControl` — a key signs, a script is spent); output preserves address and value ≥ spent. Dispute verdicts read `opArbiter`, a second credential, not `opAdmin` (ADR 0005).
  `applyOracleAdminAction` computes expected new datum on-chain. Use
  `Utils.checkTxOutAtIndexWithDatumMinValueAndAddress` with the spent input's value (balancer may add lovelace).
  **`OracleAdminAction` must include `SetAdmin`** — the Belt System's omission made its admin key
  unrotatable, which is inherited fix #2.
- **Expected datum on state change**: When the output datum may differ, the redeemer carries the action and
  the validator computes the expected new datum on-chain. Keep off-chain and on-chain update logic in sync.
- **Token flow**: Tokens locked at a validator must remain at that validator (same address and value on
  output) unless the design explicitly burns or moves them. Continuing outputs must allow value ≥ spent
  value (use min-value check).
- **Time**: any date carried in a datum is validated against the transaction's validity interval — never
  trusted as supplied (inherited fix #4).
- **Lookups**: `Palmares.Onchain.Protocol.Lookup` holds exactly three live readers —
  `readOracleParams`, `feeFor` and `checkFee`. The `unsafeGet*` profile helpers it used to export were deleted with `Protocol/Id.hs`;
  there has never been an `unsafeGetAttestation`. `Utils.checkAndGetCurrentStateDatumAndValue` and its
  helper `checkAndGetInlineDatum` are gone too, for the same reason: the Haddock at `Lookup.hs:7` said
  validators read a profile through the first and that was false (audit `NEW-OC-5`), so its trace
  codes `U2`/`U3` could never be emitted and are now retired rather than reassigned. A validator reads
  its own input with `Utils.unsafeFindOwnInputByTxOutRef` and parses the datum `SpendingScript` hands
  it; the oracle comes in as a reference input via `readOracleParams`.

### Deployment

- Oracle NFT must mint before MintingPolicy compilation (parameterized by oracle AssetClass).
- Oracle NFT Policy is **inlined** (not deployed as reference script).

## Security Rules

Based on Cardano Developer Portal and MLabs vulnerability patterns.

1. **Other redeemer**: Explicitly require expected redeemer; new easy redeemers can bypass intended checks.
2. **Other token name**: Constrain **full** minted value, not just one token name. `assetClassValueOf` alone
   is insufficient.
3. **Arbitrary datum**: Validate datum type on every legit UTxO, even if not "used" by current path.
4. **Unbounded datum**: Upper-bound datum size; no ever-growing lists/maps.
5. **Unbounded value**: Disallow extra/foreign tokens in locked outputs.
6. **Unbounded inputs**: Ensure bounded input count per protocol tx.
7. **Double satisfaction**: Reason about **all** inputs, mints, and withdrawals, not just "own" input.
8. **Missing UTxO authentication**: Use unique NFT to authenticate protocol UTxOs (e.g., oracle).
9. **Time handling**: Use correct validity interval bound (lower for "past deadline", upper for "before
   start"). Never use interval midpoint.
10. **Token security**: Limit token types in protocol UTxOs. Test with enlarged values.
11. **UTxO contention**: Prefer parallelizable/distributed state over single global UTxO.
12. **Cheap spam**: Ensure legit actions complete despite attacker spam.
13. **Staking control**: Reason about full addresses (payment + staking credential).
14. **Locked value**: Document economic tradeoff when value is permanently locked.
