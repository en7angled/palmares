{-# LANGUAGE NoImplicitPrelude #-}

-- | On-chain utility functions shared across validators.
-- Provides helpers for untyped lambda conversion, datum/value lookups,
-- output validation, and oracle reading. Minimum lovelace for state outputs
-- comes from the oracle ('opMinUTxOValue'), not from this module.
module Palmares.Onchain.Utils
  ( -- * Helper Functions
    mkUntypedLambda,
    nameFromTxOutRef,

    -- * Datum Helper Functions
    checkTxOutAtIndexWithDatumValueAndAddress,
    isTxOutAtIndexWithDatumValueAndAddress,
    checkTxOutAtIndexWithDatumMinValueAndAddress,
    valueAtOutputIdx,
    isTxOutAtIndexWithDatumMinValueAndAddress,
    isGivenInlineDatum,
    unsafeFindOwnInputByTxOutRef,
    isUnbackedDatum,

    -- * Validate and Get
    checkAndGetCurrentStateDatumAndValue,
    checkAndGetInlineDatum,

    -- * Asset Class Helpers
    hasCurrencySymbol,

    -- * Inputs Spend TxOutRef Helper Functions
    hasTxInAtAddressWithNFT,
    inputsSpendTxOutRef,
    spentExactlyOnceFromAddress,

    -- * Credential Control
    checkCredentialControl,

    -- * Time
    checkDateInRange,
    maxDateWindow,
  )
where

import Palmares.Onchain.CIP68 (isRefTokenName)
import PlutusLedgerApi.V1 qualified as V1
import PlutusLedgerApi.V1.Value
import PlutusLedgerApi.V3
import PlutusTx.Builtins
import PlutusTx.List qualified
import PlutusTx.Prelude

-------------------------------------------------------------------------------

-- * Helper Functions

-------------------------------------------------------------------------------

-- | Converts a typed validator lambda to the untyped form expected by Plutus.
{-# INLINEABLE mkUntypedLambda #-}
mkUntypedLambda ::
  (ScriptContext -> Bool) ->
  (BuiltinData -> BuiltinUnit)
mkUntypedLambda f c = check $ f (parseData c "U0") -- Invalid context (U0)
  where
    parseData mdata message = case fromBuiltinData mdata of
      Just d -> d
      _ -> traceError message

{-# INLINEABLE nameFromTxOutRef #-}
nameFromTxOutRef :: TxOutRef -> BuiltinByteString
nameFromTxOutRef (TxOutRef (TxId txIdbs) txIdx) = blake2b_224 (txIdbs `appendByteString` integerToByteString BigEndian 0 txIdx)

-------------------------------------------------------------------------------

-- * Datum Helper Functions

-------------------------------------------------------------------------------

-- | Check that the output at a specific index has the expected datum, value, and address.
-- This is more efficient than searching through all outputs with hasTxOutWithInlineDatumAndValue.
{-# INLINEABLE checkTxOutAtIndexWithDatumValueAndAddress #-}
checkTxOutAtIndexWithDatumValueAndAddress :: (ToData a) => Integer -> a -> Value -> Address -> [TxOut] -> Bool
checkTxOutAtIndexWithDatumValueAndAddress idx datum value address outputs =
  isTxOutAtIndexWithDatumValueAndAddress datum value address (outputs !! idx)

{-# INLINEABLE isTxOutAtIndexWithDatumValueAndAddress #-}
isTxOutAtIndexWithDatumValueAndAddress :: (ToData a) => a -> Value -> Address -> TxOut -> Bool
isTxOutAtIndexWithDatumValueAndAddress datum value address TxOut {txOutValue, txOutAddress, txOutDatum} =
  (value == txOutValue) && (address == txOutAddress) && isGivenInlineDatum datum txOutDatum

-- | Check that the output at a specific index has the expected datum and address, and that its value is >= minValue.
-- Use this in the minting policy where the exact output value depends on datum size (min-ADA); we only require value >= (minLv + NFT).
--
-- __THE ADDRESS COMPARISON IS THE WHOLE ADDRESS, STAKING CREDENTIAL INCLUDED.__ Plutus's 'Address'
-- is a payment credential and an @addressStakingCredential@, and @==@ compares both. Every protocol
-- address is built with @Nothing@ for the staking part, so a state output carrying ANY staking
-- credential is refused — by @Mk@, @Mp5@ and @Md5@ at the mint, and by @O2@, @P2@ and @D2@ on the
-- spend. That is deliberate, and this is the record of it, because `onchain-lib/CLAUDE.md` rules 13
-- and 14 ask for exactly this paragraph and it was the one protocol-wide tradeoff here with no
-- comment anywhere.
--
-- __Why no staking credential.__ These UTxOs hold min-ADA plus deposits that come back; the ADA is
-- the cost of a record, not a position someone is holding. Delegating it would raise a question no
-- product requirement asks: rewards accrue to the stake address and not to the UTxO, so a staked
-- script address would accumulate a balance movable only by a withdrawal certificate signed by the
-- stake credential — a second key, with no owner named anywhere in this protocol, guarding funds
-- whose claimant is genuinely ambiguous between the registry and the depositors.
--
-- __And why the check stays whole-address rather than payment-part-only.__ Relaxing it is the
-- obvious way to permit a staking credential, and it is strictly weaker: two addresses sharing a
-- payment credential and differing in their staking part are DIFFERENT addresses that the protocol
-- would then both treat as its own, which makes that set unbounded and gives an attacker a family of
-- addresses to land state at. The strict comparison is one equality and buys the opposite.
--
-- __The locked value, which is rule 14's half of this.__ Per state UTxO: min-ADA, set by the
-- oracle's @opMinUTxOValue@, locked for the life of the record — and that is PERMANENT, because
-- nothing in this protocol burns, so no record is ever removed and no min-ADA ever returns. It is
-- the price of a record that cannot be retracted, which is the property the registry exists to
-- offer. Per open dispute: @opDisputeDeposit@, which returns on either verdict (see @D4@) and is
-- therefore not locked value at all, only posted collateral.
--
-- __This must be decided before the first deployment and is now decided.__ Changing it afterwards
-- is not a redeploy but a registry migration: the protocol's addresses are derived from the
-- validator hashes, so a different address means a different minting policy and therefore a
-- different currency symbol — every existing id becomes an id under a dead policy.
{-# INLINEABLE checkTxOutAtIndexWithDatumMinValueAndAddress #-}
checkTxOutAtIndexWithDatumMinValueAndAddress :: (ToData a) => Integer -> a -> Value -> Address -> [TxOut] -> Bool
checkTxOutAtIndexWithDatumMinValueAndAddress idx datum minValue address outputs =
  isTxOutAtIndexWithDatumMinValueAndAddress datum minValue address (outputs !! idx)

{-# INLINEABLE isTxOutAtIndexWithDatumMinValueAndAddress #-}
isTxOutAtIndexWithDatumMinValueAndAddress :: (ToData a) => a -> Value -> Address -> TxOut -> Bool
isTxOutAtIndexWithDatumMinValueAndAddress datum minValue address TxOut {txOutValue, txOutAddress, txOutDatum} =
  (txOutValue `geq` minValue) && (address == txOutAddress) && isGivenInlineDatum datum txOutDatum

{-# INLINEABLE hasTxInAtAddressWithNFT #-}
hasTxInAtAddressWithNFT :: AssetClass -> Address -> [TxInInfo] -> Bool
hasTxInAtAddressWithNFT ac address = any (\(TxInInfo _inOutRef (TxOut {txOutAddress, txOutValue})) -> (address == txOutAddress) && (V1.assetClassValueOf txOutValue ac == 1))

{-# INLINEABLE inputsSpendTxOutRef #-}
inputsSpendTxOutRef :: TxOutRef -> [TxInInfo] -> Bool
inputsSpendTxOutRef spendingTxOutRef = any ((== spendingTxOutRef) . txInInfoOutRef)

-- | Is this address spent from exactly once in this transaction?
--
-- __This is the guard against multiple satisfaction__, and it is needed wherever a validator proves
-- an obligation with @any@ over the transaction's outputs. Two instances of the same script, spent in
-- one transaction, each run their own check against the SAME output list — so one output that happens
-- to satisfy both lets the second obligation be discharged for free.
--
-- Concretely, the case that found this: the Disputes Validator's @D4@ required the deposit to come
-- back with @any paysDeposit txInfoOutputs@, and two open disputes naming the same payout address (one
-- person contesting two attestations, which is the ordinary case) could be resolved in a single
-- transaction with ONE deposit returned. The second deposit left the script and landed in the
-- transaction's change, which belongs to whoever built it — the oracle admin, since @D1@ requires
-- their signature. One output, two obligations discharged, one deposit stolen.
--
-- __Why uniqueness of the input and not uniqueness of the output.__ Pinning the output by index does
-- not help: both script instances can name the same index. Tagging the output with the dispute's own
-- identifier would work and would preserve batching, at the cost of forcing a datum onto a payout to
-- an ordinary key address. Refusing the batch is one comparison, needs nothing of the recipient, and
-- gives up only an ability nobody asked for — dispute resolution is admin-driven and one at a time.
--
-- The address is the script's own, read off the input being spent, so this counts instances of THIS
-- script and not of scripts in general. A transaction may still carry other scripts' inputs.
{-# INLINEABLE spentExactlyOnceFromAddress #-}
spentExactlyOnceFromAddress :: V1.Address -> [TxInInfo] -> Bool
spentExactlyOnceFromAddress address inputs = go inputs 0
  where
    -- Counted with an early exit rather than `length . filter`: two is already a refusal, and this
    -- runs inside a validator where the list is attacker-sized.
    go [] n = n == (1 :: Integer)
    go (TxInInfo _ TxOut {txOutAddress} : rest) n
      | txOutAddress /= address = go rest n
      | n >= 1 = False
      | otherwise = go rest (n + 1)

-------------------------------------------------------------------------------

-- * Time

-------------------------------------------------------------------------------

-- | Is this date inside the transaction's validity interval, with that interval actually bounded?
--
-- __Inherited fix #4.__ `onchain-lib/CLAUDE.md` requires that any date carried in a datum is
-- validated against the transaction's validity interval, and the inherited check was
-- @date \`before\` txInfoValidRange@. That blocks __future__-dating and leaves __back__-dating
-- completely unbounded: an attestation could claim 2015 and pass. The remedy is containment, not
-- precedence.
--
-- __Both bounds must be finite__, and that is the half the old check got wrong twice over.
-- @PlutusLedgerApi.V1.Interval.before@ is @False@ for a @NegInf@ lower bound, which happened to force
-- a lower bound for that one comparison — but containment alone would be satisfied by an interval with
-- no upper bound, and a transaction submitted with @always@ could then date a permanent record
-- anywhere. So the finiteness is required explicitly rather than inferred from whichever comparison
-- the caller happens to use.
--
-- __And the interval must be NARROW, which is the half fix #4 still got wrong.__ This function used
-- to be @isBounded range && member date range@, and its own Haddock gave the refutation away: it said
-- "the caller's window is what gives this meaning: off-chain builds a ~7h window from the chain tip".
-- The caller is whoever builds the transaction, and an attacker is a caller. Finiteness alone costs
-- them nothing: they submit @Interval (Finite 2015-01-01) (Finite now+2h)@, which is finite at both
-- ends, is accepted by the ledger because the current slot lies inside it, and contains any date they
-- like. So back-dating was still completely unbounded — exactly the hole fix #4 was written to close,
-- surviving the fix because containment was checked and WIDTH was not.
--
-- The remedy is to bound the width on chain, so "inside the interval" means "within hours of chain
-- time" because the validator says so, not because the honest builder happens to be polite.
--
-- __Why a constant and not an oracle parameter.__ Every other protocol constant here is oracle-tunable
-- precisely so a redeploy is not needed to change it, and this one deliberately is not: it is a
-- statement about what a date in this registry MEANS, not a price. An admin who could widen it could
-- retroactively make every back-dated record valid, which is the attack the bound exists to stop.
-- Promoting it later is a one-field change if the window is ever genuinely wrong.
--
-- __Why TWICE the honest window and not four times, which is what this said until 2026-10-22.__ The
-- refuted sentence was "four times the off-chain builder's @safeEraTime@, so an honest transaction
-- built with that window has a wide margin". There is nothing for a margin to absorb: this bound
-- limits the interval's WIDTH, and
-- 'Palmares.TxBuilding.Skeletons.txIsValidForSafeEra' builds exactly @[tip, tip + safeEraTime]@, so
-- the honest width is a deterministic 1x and never varies. The surplus was therefore entirely the
-- attacker's, and it is the whole of their budget: the back-dating reach of a forged interval is
-- exactly @maxDateWindow@, because the ledger only requires the current slot to lie inside it, so
-- @[now - maxDateWindow, now]@ is always available. Four times bought 28.8h of back-dating on a
-- permanent record; twice buys 14.4h.
--
-- Not 1x, which would be the tightest honest value, because at 1x the honest width EQUALS the bound
-- and passes only by the @<=@. Anything that widens the builder's interval — a wallet that pads it,
-- a later @safeEraTime@ bump, a co-signing flow that needs longer to collect signatures — would then
-- be refused by the validator rather than by a reviewed decision. 2x leaves a full honest window of
-- room and still halves the attacker's reach.
--
-- A claim about an earlier event is self-reported and belongs in the claimed period or in metadata,
-- labelled as such — which is what those fields are for.
--
-- The read layer can narrow this further at no on-chain cost, by comparing @attestationDate@ against
-- the block time of the transaction that carried it; the chain cannot, because the only clock a
-- validator has is the interval it is being asked to trust.
{-# INLINEABLE maxDateWindow #-}
maxDateWindow :: POSIXTime
maxDateWindow = POSIXTime 51840000 -- 2 * safeEraTime, in milliseconds

{-# INLINEABLE checkDateInRange #-}
checkDateInRange :: POSIXTime -> V1.POSIXTimeRange -> Bool
checkDateInRange date range = case range of
  V1.Interval (V1.LowerBound (V1.Finite lo) _) (V1.UpperBound (V1.Finite hi) _) ->
    hi - lo <= maxDateWindow && V1.member date range
  _ -> False

-------------------------------------------------------------------------------

-- * Credential Control

-------------------------------------------------------------------------------

-- | Does this transaction demonstrate control of the given credential?
--
-- __This is the identity claim's whole rule__, and the spec states it in one sentence: /prove you can
-- spend as that credential/. It applies identically to a DRep id, a constitutional-committee cold
-- credential and a stake credential, because all three are a 'Credential' — which is also what CIP-129
-- encodes, header byte included, so the key-or-script distinction is never thrown away.
--
--   * __A key credential__ is controlled by whoever can make the transaction carry its signature. One
--     list membership, and it is the @extra signatory@ the spec names.
--
--   * __A script credential__ is controlled by whoever can get the ledger to spend an input that
--     script governs — in the payment half of its address or in the staking half. We do not verify
--     the script's own condition and could not: if the ledger is spending that input, the condition
--     was /already/ satisfied, before this validator ran. A native timelock or multisig script has no
--     redeemer for us to inspect anyway, and committees and multisig organisations are the majority
--     case the spec calls out.
--
-- __The payment half ONLY, and the staking half is a security hole.__ This check used to read
-- @payment == credential || staking == Just (StakingHash credential)@, on the reasoning that a stake
-- credential which is a script appears in the staking half of an address, so checking only payment
-- would make "I cannot claim my own stake script" a support question. That reasoning is wrong, and
-- the mistake was treating an address as evidence.
--
-- Spending a UTxO proves control of its __payment__ credential and nothing else: that is the only
-- part the ledger's witness rule authenticates. The staking half is attacker-chosen data. A CIP-19
-- type-2 address — payment key hash plus stake SCRIPT hash — is perfectly ordinary and needs no
-- witness for the script, so anyone could send themselves 5 ADA to an address carrying their own key
-- in the payment half and a victim's script hash in the staking half, spend it with their own
-- signature, and the disjunct would accept it as proof of controlling the victim's credential. Every
-- script DRep id and every constitutional-committee cold script credential was claimable by anyone.
--
-- Nothing legitimate used it either: the off-chain prover
-- 'Palmares.TxBuilding.Operations.claimProofSkeleton' searches @utxosAtPaymentCredential@, so no
-- honest claim ever took that branch.
--
-- __What this costs, stated rather than hidden.__ A credential that is a stake script genuinely
-- cannot be claimed this way, because spending cannot witness it. The sound proof for one is a
-- withdrawal in @txInfoWdrl@, which the ledger DOES authenticate — not an address field. That is a
-- separate feature with its own ExUnits cost, and it is not needed for the credentials this registry
-- is about: a DRep id and a committee cold credential are the voter's own credential, not an
-- address's staking part.
--
-- __The documented limitation.__ A Plutus script that holds no UTxO at its own address — one that only
-- ever votes or withdraws — cannot claim in a single transaction. Its workaround is one transaction:
-- send yourself a UTxO at your own script address, then claim. We deliberately do __not__ inspect
-- @txInfoRedeemers@ to cover that case: it would cost ExUnits on every claim to serve a case whose
-- workaround is free, which is the trade this repository rejects by standing rule.
--
-- __What control is not.__ This proves control of a credential, not the identity of whoever holds it —
-- the only thing a chain can prove. Nothing downstream may phrase it as "is"; the wording is
-- "controls this credential".
--
-- Takes the two lists rather than a @TxInfo@ so that the rule is a pure function of its actual inputs:
-- it is cheaper to pass, and it is what makes the rule unit-testable without building a transaction.
{-# INLINEABLE checkCredentialControl #-}
checkCredentialControl :: Credential -> [PubKeyHash] -> [TxInInfo] -> Bool
checkCredentialControl credential signatories inputs = case credential of
  PubKeyCredential pkh -> PlutusTx.List.elem pkh signatories
  ScriptCredential _ -> any inputGovernedByCredential inputs
  where
    -- The PAYMENT half only. The staking half is not evidence; see the note above.
    inputGovernedByCredential (TxInInfo _ TxOut {txOutAddress = Address payment _}) =
      payment == credential

{-# INLINEABLE isGivenInlineDatum #-}
isGivenInlineDatum :: (ToData a) => a -> OutputDatum -> Bool
isGivenInlineDatum datum outdat = case outdat of
  OutputDatum da -> toBuiltinData datum == getDatum da
  _ -> False

{-# INLINEABLE unsafeFindOwnInputByTxOutRef #-}
unsafeFindOwnInputByTxOutRef :: TxOutRef -> [TxInInfo] -> TxOut
unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs =
  let i = PlutusTx.List.find (\TxInInfo {txInInfoOutRef} -> txInInfoOutRef == spendingTxOutRef) txInfoInputs
   in case i of
        Just (TxInInfo _inOutRef inOut) -> inOut
        Nothing -> traceError "U1" -- Cannot find own input by TxOutRef (U1)

-- | Does the UTxO being spent FAIL to back the state NFT its own datum names — is it dust wearing a
-- datum rather than protocol state?
--
-- __This is the whole of the @Cleanup@ guard__ in all three state validators, and it replaces one
-- that asked a weaker question. The inherited arm allowed the spend when the datum was absent or did
-- not parse and refused it when the datum parsed, which made \"parses as my state\" mean \"is my
-- state\". It is not the same thing, and nothing in this protocol burns: anyone could park a min-ADA
-- UTxO at any of the three state addresses carrying a hand-written datum — a copy of a real one will
-- do — and nobody could ever sweep it. Cheap, permanent, irreversible clutter in
-- 'Palmares.TxBuilding.Lookups.getDustUTxOs' and in every address scan the read layer does, which is
-- exactly what the @Cleanup@ redeemer exists to prevent.
--
-- A datum is only protocol state if the VALUE backs it. Every state datum names its own NFT
-- ('Palmares.Onchain.Protocol.Types.profileId', @attestationId@, @disputeId@), so the question each
-- validator can actually ask is whether its own input holds that asset — the authentication the
-- inherited check skipped. The caller sweeps when this is 'True' and refuses with its own trace code
-- (@P7@, @A4@, @D8@) when it is 'False'. Those are codes of their own and not the validators' datum
-- codes, because "this datum is not protocol state" and "it IS protocol state and you may not sweep
-- it" are different mistakes — the second is somebody attempting to delete a live record.
--
-- __This cannot sweep real state__, and the reason is the token flow rather than this function. A
-- state NFT is minted exactly once into a UTxO whose whole datum the minting policy pinned
-- (@Mp5@/@Mk@/@Md5@), no redeemer burns, and the only redeemer that can move it requires the own
-- value to hold it (@P2@/@A1@/@D2@) and re-locks at least that value at the same address with a
-- datum the validator computed. So a genuine state NFT can only ever sit in a UTxO whose datum
-- parses and names it, where this returns 'False'.
--
-- __What it does newly sweep, said plainly:__ a UTxO holding some OTHER protocol token than the NFT
-- its datum names — a user token mis-sent to a state address with a hand-written datum on it. That
-- was already true of a token mis-sent with no datum or a broken one, which the two arms above have
-- always swept, so this makes the parsing case behave like the unparseable one rather than opening a
-- new door. Nobody can move a token someone else holds, so the only way into that state is the
-- holder's own transaction, and the alternative was that the token stayed there forever: @P2@ refuses
-- an update whose own value lacks the Ref NFT, so such a UTxO had no spending path at all.
--
-- __Why @== 0@ and not @\/= 1@__, which differ only at a quantity of two or more: that quantity
-- cannot exist, because every mint path constrains the WHOLE minted value to one NFT. If it somehow
-- did, the UTxO would be holding a genuine state NFT, and refusing the sweep is the safe side of
-- that question — the expensive mistake here is sweeping real state, not leaving a UTxO unswept.
-- __AND THE NAME MUST BE A CIP-67 REFERENCE NAME, which is the half this function shipped without.__
-- "A protocol NFT backs this datum" and "the NFT this datum names is a protocol STATE NFT" are
-- different statements, and only the first was checked. The gap is the same one @Mg@ and @Md4@ were
-- upgraded over on the same day, at the site that decides whether a UTxO is state rather than at the
-- sites that read an id out of a redeemer.
--
-- The plant it let stand: mint a profile legitimately — nothing constrains where @Mp2@'s USER token
-- goes, by CIP-68 design — and pay that user token, plus a hand-written datum naming it as a
-- @profileId@ \/ @attestationId@ \/ @disputeId@, to a state address. No script runs; paying TO a
-- script address needs no witness. The datum parses, the value holds exactly 1 of the token it
-- names, so this returned @False@ and every @Cleanup@ was refused — permanently, because nothing
-- burns. The read layer's own gate had the identical gap, which is how the plant became a forged
-- ACCEPTED attestation attributed to a victim; see
-- 'Palmares.TxBuilding.Utils.authenticateStateUTxO'.
--
-- The prefix is checkable here and the currency symbol is not: these three validators are
-- unparameterised on purpose, so they cannot know the policy that minted a token, but a CIP-67
-- prefix is four bytes of the name and policy-independent. So this closes the USER-token plant
-- completely, and narrows — does not close — a plant naming a ref-prefixed token of the attacker's
-- OWN policy. That residue is permanent clutter at min-ADA plus a self-mint, with no forgery
-- attached, and closing it needs a parameter these validators deliberately do not take.
-- | The value of the output at this index, or a script failure if the index names none.
--
-- @PlutusTx.List.!!@ traces on a negative index and past the end, so an out-of-range index fails
-- the script rather than returning something. Used where a check is about what an output does NOT
-- contain, which 'checkTxOutAtIndexWithDatumMinValueAndAddress' cannot express: its `geq` says
-- "at least this", so it positively permits extra tokens.
{-# INLINEABLE valueAtOutputIdx #-}
valueAtOutputIdx :: Integer -> [TxOut] -> Value
valueAtOutputIdx idx outputs = txOutValue (outputs PlutusTx.List.!! idx)

{-# INLINEABLE isUnbackedDatum #-}
isUnbackedDatum :: AssetClass -> TxOutRef -> [TxInInfo] -> Bool
isUnbackedDatum stateNFT@(AssetClass (_, tn)) spendingTxOutRef txInfoInputs =
  not (isRefTokenName tn)
    || V1.assetClassValueOf (txOutValue (unsafeFindOwnInputByTxOutRef spendingTxOutRef txInfoInputs)) stateNFT == 0

-------------------------------------------------------------------------------

-- * Validate and Get - Datum and Value Helper Functions

-------------------------------------------------------------------------------

{-# INLINEABLE checkAndGetCurrentStateDatumAndValue #-}
checkAndGetCurrentStateDatumAndValue :: V1.AssetClass -> Address -> [TxInInfo] -> (Value, BuiltinData)
checkAndGetCurrentStateDatumAndValue stateToken addr outs =
  case filter (\(TxInInfo _inOutRef (TxOut {txOutValue, txOutAddress})) -> (txOutValue `geq` V1.assetClassValue stateToken 1) && (addr == txOutAddress)) outs of
    [TxInInfo _inOutRef out] -> (txOutValue out, checkAndGetInlineDatum out)
    _ -> traceError "U2" -- Cannot find state NFT at expected address (U2)

{-# INLINEABLE checkAndGetInlineDatum #-}
checkAndGetInlineDatum :: TxOut -> BuiltinData
checkAndGetInlineDatum out = case txOutDatum out of
  OutputDatum da -> getDatum da
  _ -> traceError "U3" -- Invalid output: expected inline datum (U3)

-------------------------------------------------------------------------------

-- * Asset Class Helpers

-------------------------------------------------------------------------------

-- | Check whether an 'AssetClass' belongs to the given 'CurrencySymbol'.
{-# INLINEABLE hasCurrencySymbol #-}
hasCurrencySymbol :: AssetClass -> CurrencySymbol -> Bool
hasCurrencySymbol (AssetClass (cs, _)) cs' = cs == cs'
