{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | What each validator costs to put on chain.
--
-- __The gap this closes.__ @TxBuilding.Validators@ has exported @profilesValidatorSize@ and its four
-- siblings since the first commit and nothing ever called them. The only place a size was ever
-- reported was a log line in @TestRuns.deployValidators@ — printed, never asserted, and for the
-- whole stretch while the emulator suite was dormant, never even printed. So a change that doubled a
-- script was indistinguishable from one that did not, right up to the deployment that paid for it.
--
-- __Two assertions, because they catch different things.__ The ceiling is correctness: a reference
-- script has to fit in a transaction, and one that does not cannot be deployed at all. The exact
-- table is economics: a validator that grew 30% still deploys, still passes every other test, and
-- quietly raises the min-ADA of every UTxO that references it. Pinning the number is what makes that
-- growth a visible diff instead of an invoice. When a change is meant to move a size, the table is
-- updated in the same commit — that update IS the record.
module UnitTests.ScriptSize (tests) where

import Palmares.TxBuilding.Validators
  ( attestationsValidatorSize,
    disputesValidatorSize,
    mintingPolicySize,
    oracleValidatorSize,
    profilesValidatorSize,
  )
import PlutusLedgerApi.V1.Value (AssetClass (..), CurrencySymbol (..), TokenName (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "script sizes"
    [ -- The whole table in one assertion, so a failure prints every size rather than the first one
      -- that moved. Flat-encoded bytes, which is what goes in the reference-script output.
      testCase "every validator is exactly the size it was when this was last reviewed" $
        assertEqual "a validator changed size — update the table in the same commit, deliberately" expected measured,
      -- The hard limit. `maxTxSize` is 16384 bytes, and the transaction that deploys a reference
      -- script carries the script PLUS its own inputs, outputs, change and witnesses. 14000 leaves
      -- about 2.4 KB for all of that, which is the margin `deployValidators` actually runs in.
      --
      -- The MintingPolicy is the one to watch: at 12241 bytes it is 75% of a whole transaction, and
      -- it is the only script that grows when a redeemer case is added. The four spending validators
      -- sit between 7.6 and 8.4 KB and have room.
      testCase "every validator leaves room for the transaction that deploys it" $
        filter ((> 14_000) . snd) measured @?= []
    ]

-- | Measured sizes, by name. The minting policy is parameterised, so it is measured against a local
-- placeholder oracle token — a real deployment's 28-byte currency symbol adds a few bytes to this
-- figure and nothing structural.
--
-- This used to say "the same placeholder oracle token the blueprint uses". It no longer does: the
-- blueprint stopped shipping a compiled minting policy at all, because applying a placeholder meant
-- publishing a CIP-57 @hash@ field that matched no deployment. A measurement against a placeholder
-- is honest; a published hash derived from one is not, which is the whole difference between these
-- two uses of the same trick.
measured :: [(String, Int)]
measured =
  [ ("ProfilesValidator", profilesValidatorSize),
    ("AttestationsValidator", attestationsValidatorSize),
    ("DisputesValidator", disputesValidatorSize),
    ("OracleValidator", oracleValidatorSize),
    ("MintingPolicy", mintingPolicySize placeholderOracleToken)
  ]
  where
    placeholderOracleToken = AssetClass (CurrencySymbol "", TokenName "")

-- | Measured on 2026-10-21, GHC 9.6.6 with the frozen plutus-tx, at the end of Plan B's Phase 2
-- (five validators, disputes included) and with traces preserved — which is the default build and
-- therefore the one that gets deployed. A toolchain bump moves all five at once and is the one case
-- where updating this table wholesale is the right response.
--
-- With traces stripped the same five measured 7707, 7410, 8032, 7293, 11482 — taken before the
-- critical fix below, and not re-measured since, because the option to strip them is gone. Traces
-- cost between 1.8% and 3.4%, which is what made keeping them an easy decision.
--
-- Every move so far, and which validators did NOT move each time — which is the useful part of this
-- table, because an unchanged number bounds a change instead of describing it:
--
--   MintingPolicy 11871 -> 11850  deleting the staking-half disjunct from 'checkCredentialControl'
--                                 (one comparison fewer) when the first audit's critical finding
--                                 was fixed. The other four did not budge.
--   MintingPolicy 11850 -> 11865  adding the interval-WIDTH check to 'checkDateInRange' when the
--                                 second audit found that inherited fix #4 had closed containment
--                                 and left width open. The other four did not budge.
--
-- Both of those functions are reached only from the minting policy, which is exactly what the four
-- unchanged numbers said.
--
-- Then the dispute-family audit fixes, three validators in one commit:
--
--   DisputesValidator 8243 -> 8340  @D6@, one dispute resolved per transaction, which is what makes
--                                   @D4@'s `any` over the outputs sound
--   OracleValidator   7427 -> 7492  @O5@, a handover must carry the INCOMING admin's signature
--   MintingPolicy    11865 -> 11920 @Md4@ extended to the dispute opener's currency symbol, and
--                                   @Md8@, the payout address must be one the tx spends from
--
-- ProfilesValidator and AttestationsValidator did not move, and that is the assertion worth having:
-- the dispute fixes touched the dispute path, the oracle fix touched the oracle, and the shared
-- helper added to 'Palmares.Onchain.Utils' ('spentExactlyOnceFromAddress') is reached from exactly
-- one validator rather than linked into all five.
--
-- Then the mint-path redeemer checks, and this is the most expensive single change so far:
--
--   MintingPolicy 11920 -> 12241  @Mn@ ('validateOtherMetadata') and the CIP-67 reference-prefix
--                                 half of @Mg@ and @Md4@ ('isProtocolRefToken'). The other four did
--                                 not budge.
--
-- 321 bytes, and almost all of it is @Mn@: the duplicate-key check is a quadratic scan written as
-- two recursive functions, and recursion is what PlutusTx cannot share. It buys a bounded datum on
-- a record nobody can remove, so it is worth it — but it is the one line in this table where the
-- cost is worth looking at again if the policy ever approaches the ceiling. The prefix check is
-- four bytes of comparison reused at four call sites.
--
-- Then the three STATE validators, and the asymmetry is the interesting part:
--
--   ProfilesValidator     7879 -> 8381  (+502)  'Utils.isUnbackedDatum' on @Cleanup@, AND @P6@ —
--                                               which had to add an oracle read this validator did
--                                               not previously do at all
--   AttestationsValidator 7554 -> 7604  (+50)   'Utils.isUnbackedDatum' alone. No pause check: an
--                                               'OnchainAttestation' carries no oracle token, and a
--                                               token taken from the redeemer would be
--                                               attacker-chosen and therefore worthless
--   DisputesValidator     8340 -> 8424  (+84)   'Utils.isUnbackedDatum' and @D7@, which is one
--                                               boolean because the oracle was already bound in the
--                                               @ResolveDispute@ arm
--
-- +50 against +502 for the same shared helper is the whole cost of REACHING the oracle, measured.
-- It is also why the Attestations validator's pause is off-chain only: the cheap routes were taken
-- and the remaining ones change either the deployed datum format or every honest client's
-- transaction. OracleValidator and MintingPolicy did not move, which says the helper is reached
-- from exactly the three validators that call it.
--
-- Then the adversarial audit of 2026-10-22, and every number below is a check that was missing:
--
--   ProfilesValidator     8381 -> 8414  (+33)
--   AttestationsValidator 7604 -> 7637  (+33)
--   DisputesValidator     8424 -> 8457  (+33)
--
-- The same +33 three times, because 'Utils.isUnbackedDatum' grew the half it was written without:
-- it asked whether the datum's named NFT is in the input's value, but not whether that NFT is a
-- CIP-67 *reference* token. A planted datum naming a USER token answered "no NFT here" and was
-- therefore classified as backed state, which made it permanently unsweepable — free, irreversible
-- address clutter. Identical cost at all three sites because PlutusTx shares nothing between
-- scripts; each compiles its own copy of the four-byte prefix comparison.
--
--   OracleValidator       7492 -> 7547  (+55)  @O6@ ('oracleParamsAreWellFormed'). `geq` is
--                                              VACUOUSLY TRUE on a negative required amount — the
--                                              `These a b -> a >= b` arm is satisfied by anything
--                                              when b is below zero — so a negative
--                                              @opMinUTxOValue@ made every min-value check in the
--                                              protocol vacuous and drained ~3.8 ADA per dispute
--                                              from the admin's own wallet
--   MintingPolicy        12241 -> 12296  (+55)  @Mp6@ and 'Utils.valueAtOutputIdx'. @Mp5@'s `geq`
--                                              POSITIVELY PERMITTED the profile's user token inside
--                                              the state output; locked there, @P3@ was satisfied by
--                                              the profile's own input and any stranger could
--                                              rewrite that profile forever
--
-- 55 bytes each, and both are the same shape of bug: a @geq@ whose direction nobody re-read. Worth
-- the pattern: every size in this table that was NOT a feature was an inequality that permitted
-- more than its sentence claimed.
--
-- __THE SIZE AUDIT OF 2026-10-22, with the five items DECLINED and why.__ Recorded here rather than
-- left in a report, because a declined item that nobody wrote down gets re-proposed. The calibration
-- the audit worked from is this table's own history: a recursion is ~45-50 bytes, a comparison
-- ~10-20, and reaching the oracle ~450.
--
-- Applied: @validateOtherMetadata@ from six recursions to three (see 'validateOtherMetadata' for
-- the argument, and @UnitTests.MintInputs@ lines 92-122 for the nine cases that already pinned it).
-- Estimated at ~135 bytes from the calibration above. __MEASURED AT 20__, 12296 -> 12276, and the
-- gap is the more useful result.
--
-- Part of it is that one of the four removed traversals never left: @elem@ is still compiled into
-- this policy through 'Palmares.Onchain.Utils.checkCredentialControl', which is @INLINEABLE@ and
-- reached from the claim path, and @any@ with it. Worth recording how that was nearly got wrong —
-- grepping @MintingPolicy.hs@ for @elem@ finds nothing, because __the compiled script is the
-- inlined whole and not one file__. @all@, @map@ and the list @<>@ were genuinely unique to
-- 'validateOtherMetadata', so the net removal is about two fixpoints, which the ~45-each
-- calibration predicts at ~90 and which measured 20.
--
-- The calibration therefore over-predicts by about four even after that correction, and the honest
-- reading is that it was derived from INTRODUCING traversals into a script that lacked them and
-- does not invert. Treat every estimate below as an upper bound.
--
-- Keep the change for the ExUnits, which is where the real return is: three traversals instead of
-- six, no intermediate @map fst@ list built, and 168 key comparisons instead of 171.
--
-- Declined, in descending order of how tempting they are:
--
--   * @checkDateInRange@ without the @Interval@ library, ~150 bytes. The three new cases in
--     @UnitTests.OracleRules@ make this SAFE to do — they pin the exclusive-upper-bound semantics
--     the ledger actually delivers — but there is no reason to do it. This is the only function
--     that dates a permanent record, and ~1700 bytes of headroom is not a reason to hand-roll
--     library semantics.
--   * @and [...]@ to @&&@ in ProfilesValidator and OracleValidator, ~90 bytes. Those lists hold the
--     @traceIfFalse@ calls, and a strict list forces all of them, so a failing transaction logs
--     EVERY failing code; @&&@ logs the first. That is a diagnostic trade, and this project already
--     took the opposite decision explicitly when it chose @preserve-logging@ over @remove-trace@ in
--     the cabal file. The AttestationsValidator and DisputesValidator sites are different — their
--     @and@ sits inside a single @traceIfFalse@, so converting them changes no diagnostics — but
--     ~90 bytes on scripts with 8 KB of headroom is not worth a diff.
--   * @valueSpent@ to a shared @inputsSpendExactlyOne@. Measured at ~0 on the minting policy: it
--     removes one @foldMap@ recursion and adds the helper's own, and does not remove @unionWith (+)@
--     because the policy sums @Value@s anyway. This project's +50-against-+502 lesson, in reverse.
--   * @checkFee@ computing @feeFor@ once, 0-20 bytes. All three call sites pass a known constructor,
--     so it very likely constant-folds already. It also needs parentheses rather than @$@ to
--     compile, since @$@ is @infixr 0@ against @||@'s @infixr 2@.
--   * @MintingContext@ removal, 0 bytes. The record is built once and field-selected in the same
--     compilation unit, so case-of-known-constructor eliminates it before UPLC is emitted. Removing
--     it could make the policy LARGER, because passing three arguments to three handlers is more
--     binders than one record.
--
-- Still declined from the earlier round, unchanged: @unsafeFromBuiltinData@ on the oracle read
-- (450-850 bytes across three scripts). It trades @K1@ — the only diagnostic on the only path that
-- reads external state — for bytes. It is the first lever if the policy ever approaches 14000.
expected :: [(String, Int)]
expected =
  [ ("ProfilesValidator", 8414),
    ("AttestationsValidator", 7637),
    ("DisputesValidator", 8457),
    ("OracleValidator", 7547),
    ("MintingPolicy", 12276)
  ]
