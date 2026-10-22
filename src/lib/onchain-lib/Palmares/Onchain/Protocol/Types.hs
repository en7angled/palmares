{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | Core on-chain data types for the Palmares attestation protocol.
module Palmares.Onchain.Protocol.Types where

import GHC.Generics (Generic)
import PlutusLedgerApi.V1.Value (AssetClass)
import PlutusLedgerApi.V3 (Address, Credential, POSIXTime, PubKeyHash, ScriptHash)
import PlutusTx
import PlutusTx.Blueprint
import PlutusTx.Prelude
import Prelude qualified

-------------------------------------------------------------------------------

-- * Protocol Parameters

-------------------------------------------------------------------------------

-- | Protocol parameters containing validator script hashes and the oracle token.
-- Baked into the MintingPolicy at compile time and embedded in datums for
-- cross-validator communication.
data ProtocolParams = ProtocolParams
  { profilesValidatorScriptHash :: ScriptHash,
    attestationsValidatorScriptHash :: ScriptHash,
    -- | Where a dispute UTxO must be locked. Appended, and the append is not free: this record is
    -- the minting policy's compile-time parameter, so it changes the policy's hash — AND it is
    -- embedded in every 'OnchainProfile' datum, so it changes the profile datum format too. Both
    -- are why disputes land before the first deployment rather than in a later increment.
    disputesValidatorScriptHash :: ScriptHash,
    oracleToken :: AssetClass
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''ProtocolParams [('ProtocolParams, 0)]
makeLift ''ProtocolParams

-------------------------------------------------------------------------------

-- * Oracle Parameters

-------------------------------------------------------------------------------

-- | Fee configuration for protocol operations.
-- When set, users must include a fee payment output in their transactions.
data FeeConfig = FeeConfig
  { -- | Address that collects fees
    fcFeeAddress :: Address,
    -- | Fee in lovelace for creating a profile
    fcProfileCreationFee :: Integer,
    -- | Fee in lovelace for issuing an attestation
    fcAttestationFee :: Integer
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''FeeConfig [('FeeConfig, 0)]

-- | Mutable operational parameters stored in the oracle UTxO datum.
-- Read as a reference input by the MintingPolicy at execution time.
data OracleParams = OracleParams
  { -- | Admin public key hash. Rotated by 'OracleSetAdmin', __signed by the current admin__.
    --
    -- This field said "can rotate itself" for a long time while that was false in the strong sense:
    -- 'OracleAdminAction' had no @SetAdmin@ case, and the validator requires the output datum to
    -- equal @applyOracleAdminAction action@ of the current one, which preserved this field by
    -- construction. Rotation was not unimplemented, it was forbidden. Inherited fix #2 added the
    -- case, and the validator needed no change — which is what tells you it was written correctly.
    --
    -- What rotation does and does not buy: a key still held can be handed on, so compromise is
    -- recoverable while you notice in time; a key already lost is not, because the rotation itself
    -- needs its signature.
    opAdminPkh :: PubKeyHash,
    -- | Protocol pause switch
    opPaused :: Bool,
    -- | Optional fee configuration
    opFeeConfig :: Maybe FeeConfig,
    -- | Minimum lovelace for protocol state outputs (used on-chain only from oracle)
    opMinUTxOValue :: Integer,
    -- | Lovelace a disputer must lock when opening a dispute, and gets back on either verdict.
    --
    -- __On 'OracleParams' and deliberately not in 'FeeConfig'__, because a returned deposit is not
    -- a fee: nobody collects it. It is also the only shape that passes @scripts/check_vocabulary.sh@,
    -- which permits a 'FeeConfig' field name in four places — a happy agreement between the semantic
    -- argument and the lint.
    --
    -- __The amount a dispute actually paid is recorded in its own datum__, not read from here at
    -- resolution time. Reading it here would let the admin lower this value, resolve, and keep the
    -- difference — or raise it and make an open dispute unresolvable. The oracle sets the price for
    -- NEW disputes; an open dispute's price is history.
    opDisputeDeposit :: Integer
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OracleParams [('OracleParams, 0)]

-- | On-chain representation of an admin action on the oracle.
-- Mirrors 'DomainTypes.Core.Actions.AdminActionType' for use in the Oracle redeemer.
data OracleAdminAction
  = OraclePause
  | OracleUnpause
  | OracleSetFees (Maybe FeeConfig)
  | OracleSetMinUTxOValue Integer
  | -- | Hand the oracle to a new admin — __inherited fix #2__.
    --
    -- Its absence did not merely leave rotation unimplemented, it __forbade__ it: the validator
    -- requires the output datum to equal @applyOracleAdminAction action@ of the current one, and
    -- without this case that function preserves 'opAdminPkh' by construction. So the validator needs
    -- no change at all; making this function able to express the change is the whole fix, and it is
    -- that cheap because the validator was written correctly.
    --
    -- Appended at index 4, never inserted: the four indices above are a deployed-data contract from
    -- the first deployment onward.
    OracleSetAdmin PubKeyHash
  | -- | Reprice the dispute deposit for NEW disputes.
    --
    -- Here for the same reason 'OracleSetMinUTxOValue' is: a protocol constant that cannot be
    -- repriced is one you must redeploy a validator to change, which is the thing the oracle exists
    -- to avoid. It cannot affect a dispute already open — that deposit is recorded in the dispute's
    -- own datum, see 'opDisputeDeposit'.
    OracleSetDisputeDeposit Integer
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''OracleAdminAction
  [ ('OraclePause, 0),
    ('OracleUnpause, 1),
    ('OracleSetFees, 2),
    ('OracleSetMinUTxOValue, 3),
    ('OracleSetAdmin, 4),
    ('OracleSetDisputeDeposit, 5)
  ]

-- | Apply an admin action to current oracle params to obtain the new params.
-- Same logic as off-chain 'TxBuilding.Operations.applyAdminAction'.
{-# INLINEABLE applyOracleAdminAction #-}
applyOracleAdminAction :: OracleAdminAction -> OracleParams -> OracleParams
applyOracleAdminAction OraclePause params = params {opPaused = True}
applyOracleAdminAction OracleUnpause params = params {opPaused = False}
applyOracleAdminAction (OracleSetFees mFeeConfig) params = params {opFeeConfig = mFeeConfig}
applyOracleAdminAction (OracleSetMinUTxOValue lovelace) params = params {opMinUTxOValue = lovelace}
applyOracleAdminAction (OracleSetAdmin newAdmin) params = params {opAdminPkh = newAdmin}
applyOracleAdminAction (OracleSetDisputeDeposit lovelace) params = params {opDisputeDeposit = lovelace}

-- | Are these oracle params usable at all?
--
-- __A NEGATIVE LOVELACE PARAMETER MAKES EVERY MIN-VALUE CHECK IN THE PROTOCOL VACUOUS__, and that
-- is a property of @geq@ rather than of any check here. 'PlutusLedgerApi.V1.Value.geq' is
-- @checkBinRel (>=)@, whose arms are @This a -> a >= 0@, @That b -> 0 >= b@ and
-- @These a b -> a >= b@ — so a required amount below zero is satisfied by anything, including
-- nothing. Verified against plutus-ledger-api 1.43.1.0, not assumed.
--
-- The concrete drain, which is why this is a check and not a comment. Set @opMinUTxOValue@ to
-- @-5_000_000@ with one @OracleSetMinUTxOValue@: a dispute's expected value becomes
-- @disputeNFT + (-5 ADA) + 5 ADA@, whose lovelace component is zero, so @Md5@ accepts a dispute
-- UTxO holding only the ledger's own minimum while its datum still records a 5 ADA deposit. At
-- resolution @ownValue - depositValue@ is negative, so @D2@ is vacuous too — and @D4@ still demands
-- 5 ADA at @disputeDepositTo@, funded by whoever builds the transaction, which @D1@ says is the
-- admin. About 3.8 ADA out of the admin's pocket per dispute, repeatable by anyone who opens one.
--
-- So it is a foot-gun to set and an attack once set, which is the combination worth one check. It
-- is checked on the RESULT rather than per action, so it covers all six actions and every future
-- one by construction — the same reason @O2@ compares the output datum against this function's
-- result instead of re-deriving each field.
--
-- Zero is permitted for both: a zero @opDisputeDeposit@ is a deliberate configuration (disputes
-- free to open), and a zero @opMinUTxOValue@ simply defers to the ledger's own minimum, which is
-- the real floor at every configured value anyway.
{-# INLINEABLE oracleParamsAreWellFormed #-}
oracleParamsAreWellFormed :: OracleParams -> Bool
oracleParamsAreWellFormed params =
  opMinUTxOValue params >= 0 && opDisputeDeposit params >= 0

-------------------------------------------------------------------------------

-- * Type Aliases

-------------------------------------------------------------------------------

type ProfileId = AssetClass

type AttestationId = AssetClass

type DisputeId = AssetClass

-------------------------------------------------------------------------------

-- * Profiles

-------------------------------------------------------------------------------

-- | What kind of actor a profile stands for.
--
-- The six the spec names: the Intersect ecosystem, its committees, its communities, and the vendors
-- and auditors who deliver and review against treasury funding. The registry is not a DRep registry.
--
-- __A constructor and not a metadata field__, although no validator branches on the kind. The read
-- layer filters and groups by it; CIP-68 metadata is a @Map BuiltinByteString BuiltinByteString@ that
-- the projection would have to parse and that a future update redeemer could silently change. One
-- byte in the datum that cannot drift.
--
-- __The enum is closed.__ A seventh kind is a redeploy, which is the right price for changing what
-- this registry recognises. @Organization@ keeps index 1, the one index that survives the rename.

-- | Which minting action a transaction is performing.
--
-- __This exists so that a fee is never selected by passing a function.__ The inherited design had
-- @checkFee :: OracleParams -> (FeeConfig -> Integer) -> [TxOut] -> Bool@, and that selector-passing
-- shape is exactly how the Belt System's interval fee ended up charging the wrong field: the caller
-- names the field, so every call site is a place the wrong name can be written. With an action, the
-- only place a @FeeConfig@ fee AMOUNT is selected is 'Palmares.Onchain.Protocol.Lookup.feeFor' — one
-- function, one naming site, no selectors. Inherited fix #1.
--
-- One constructor per minting redeemer, and the correspondence is the point: adding a redeemer without
-- adding an action leaves @feeFor@ non-exhaustive, which is a compile error rather than a silent zero.
data MintAction
  = MintActionProfile
  | MintActionAttestation
  | MintActionDispute
  -- @Prelude.Enum@/@Prelude.Bounded@ are for the TESTS, not for the validator: PlutusTx never sees
  -- them. They let @UnitTests.Fees@ drive itself off @[minBound .. maxBound]@, so a fourth action
  -- is covered the moment it is added rather than when someone remembers to extend a list. The
  -- list that was there named two actions and claimed to be every action.
  deriving stock (Generic, Prelude.Show, Prelude.Eq, Prelude.Enum, Prelude.Bounded)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''MintAction
  [ ('MintActionProfile, 0),
    ('MintActionAttestation, 1),
    ('MintActionDispute, 2)
  ]

data OnchainProfileKind
  = PersonDRep
  | Organization
  | Committee
  | Community
  | Vendor
  | Auditor
  -- Enum/Bounded are Haskell-only and generate no Plutus code, so the script hash is unaffected.
  -- They are here so that a test can enumerate the kinds instead of restating them: a list someone
  -- has to remember to extend is a list that will not be extended.
  deriving stock (Generic, Prelude.Show, Prelude.Eq, Prelude.Enum, Prelude.Bounded)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''OnchainProfileKind
  [ ('PersonDRep, 0),
    ('Organization, 1),
    ('Committee, 2),
    ('Community, 3),
    ('Vendor, 4),
    ('Auditor, 5)
  ]

data OnchainProfile
  = OnchainProfile
  { profileId :: ProfileId,
    profileKind :: OnchainProfileKind,
    -- | The Cardano credential this profile claims, if any.
    --
    -- A 'Credential' and not a bare hash, because that is what CIP-129 encodes — header byte
    -- included — so the key-or-script distinction the claim rule turns on is never thrown away. It
    -- covers a DRep id, a constitutional-committee cold credential and a stake credential
    -- identically, which is why the claim rule needs no per-kind cases.
    --
    -- __'Nothing' is legitimate.__ A Community or an Auditor need not correspond to any on-chain
    -- credential, and requiring one would make the registry refuse actors the spec names. What
    -- 'Nothing' means is "this profile claims nothing", which the read layer must present as
    -- @unclaimed@ — never as verified.
    profileCredential :: Maybe Credential,
    protocolParams :: ProtocolParams
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OnchainProfile [('OnchainProfile, 0)]

-------------------------------------------------------------------------------

-- * Attestation

-------------------------------------------------------------------------------

-- | What an attestation asserts about its subject.
--
-- The five the spec names (§3): a budget administrator attesting a vendor's delivery, an auditor
-- attesting that it reviewed one, an organisation ↔ member affiliation, an extra-chain mandate such
-- as a working-group lead or a committee chair, and a plain endorsement.
--
-- __A constructor and not a metadata key__, for the same reason 'OnchainProfileKind' is: the read
-- layer filters and groups by it, CIP-68 metadata is a @Map BuiltinByteString BuiltinByteString@ the
-- projection would have to parse, and an update redeemer could silently change a metadata key. One
-- byte in the datum that cannot drift.
--
-- __No validator branches on it__, and that is deliberate. The kind decides what a reader is being
-- told, not what the protocol permits: every kind is minted, accepted and disputed identically. A
-- per-kind rule would be a per-transaction ExUnits cost buying a distinction the counter-signature
-- already makes.
--
-- The enum is closed; a sixth kind is a redeploy. Indices are append-only from the first deployment.
data AttestationKind
  = MilestoneDelivered
  | AuditPassed
  | Affiliation
  | RoleHeld
  | Endorsement
  -- As with 'OnchainProfileKind': Haskell-only, hash-neutral, and what lets the round-trip test
  -- cover a sixth kind the day it is added. The domain mirror 'DomainTypes.Core.Types.AttestationType'
  -- already derives both.
  deriving stock (Generic, Prelude.Show, Prelude.Eq, Prelude.Enum, Prelude.Bounded)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''AttestationKind
  [ ('MilestoneDelivered, 0),
    ('AuditPassed, 1),
    ('Affiliation, 2),
    ('RoleHeld, 3),
    ('Endorsement, 4)
  ]

data OnchainAttestation = OnchainAttestation
  { attestationId :: AttestationId,
    attestationIssuer :: ProfileId,
    attestationSubject :: ProfileId,
    attestationKind :: AttestationKind,
    -- | When the attestation was __issued__, and the only date on this record the chain says anything
    -- about: 'Palmares.Onchain.Utils.checkDateInRange' requires it to be contained in the
    -- transaction's validity interval, which off-chain builds from the chain tip. Inherited fix #4.
    attestationDate :: POSIXTime,
    -- | The period the attestation __claims__, and it is __self-reported__.
    --
    -- The spec requires it: @Affiliation@ and @RoleHeld@ are defined /with intervals/, and an
    -- affiliation that began before the attestation was issued is the normal case — "a member since
    -- March 2024, attested today" — not an edge case. So the strict reading, where an attestation can
    -- only ever date itself, was never available.
    --
    -- __It is deliberately NOT validated against the validity interval, and must never be.__
    -- Validating it would be a lie: nothing on chain can confirm when a membership began. That is
    -- also why the validator gains no rule for it — there is nothing to check. What stops a nonsense
    -- period is the same thing that stops a nonsense attestation: the subject has to counter-sign it.
    -- An inverted period is refused off-chain as a bad request, which is where a client can be told
    -- why.
    --
    -- A @Maybe@ of a PAIR rather than two optional bounds, so "both or neither" is structural. A
    -- half-open period would be a third state the read layer would have to render, and an open-ended
    -- affiliation is expressed by the period's end being the far future, not by its absence.
    --
    -- The read layer must present this as claimed, never as verified — @claimed_period@ beside
    -- @issued_at@ — and must not sort or filter the record as though the chain had checked it.
    attestationPeriod :: Maybe (POSIXTime, POSIXTime),
    attestationIsAccepted :: Bool
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OnchainAttestation [('OnchainAttestation, 0)]

-------------------------------------------------------------------------------

-- * Dispute

-------------------------------------------------------------------------------

-- | How a dispute was decided.
--
-- Two outcomes and no third, because the deposit comes back either way: there is no "frivolous"
-- verdict to punish, and adding one would turn the deposit into a fine the admin levies. The
-- consequence of a verdict is entirely a read-layer one — an upheld dispute is shown beside the
-- attestation it contests, and __the attestation is never hidden or deleted__ (spec §4.3). The
-- record of a claim and the record of its being contested are both facts; suppressing the first
-- would make the second unreadable.
data Verdict
  = VerdictUpheld
  | VerdictRejected
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''Verdict [('VerdictUpheld, 0), ('VerdictRejected, 1)]

-- PlutusTx's 'Eq', not the stock one above: under @NoImplicitPrelude@ the @==@ a validator compiles
-- is this class, and the derived @Prelude.Eq@ is invisible to it. Written out rather than derived
-- because PlutusTx has no deriving for it.
instance Eq Verdict where
  {-# INLINEABLE (==) #-}
  VerdictUpheld == VerdictUpheld = True
  VerdictRejected == VerdictRejected = True
  _ == _ = False

-- | A dispute: one profile contesting one attestation, with a deposit behind it.
--
-- __A separate UTxO pointing at an attestation, never a field on the attestation.__ That is what
-- keeps the attestation path's ExUnits exactly as they were — 'OnchainAttestation' and the
-- Attestations Validator learn nothing about disputes — and it is also what lets a dispute exist
-- without the subject's or the issuer's cooperation.
--
-- Three of these fields are not in the plan's sketch of this type, and each is here because the
-- plan's own checks cannot be written without it:
--
--   * __'disputeOracleToken'__ — @ResolveDispute@ requires the oracle admin's signature, and an
--     unparameterised validator cannot tell which reference input IS the oracle without the token
--     that identifies it. Without this field anyone could supply a forged \"oracle\" UTxO naming
--     themselves as admin. Only the token, not the whole 'ProtocolParams': it is all this validator
--     needs, and a datum is paid for in min-ADA.
--   * __'disputeDepositTo'__ — the deposit has to go back to the disputer, and a validator cannot
--     resolve a 'ProfileId' into an address. The disputer names the address when opening, and @Md8@
--     requires it to be one the opening transaction spends from. Not "pointing it somewhere useless
--     only costs them", which is what this said and is false: @D4@ pays with
--     @txOutAddress == disputeDepositTo@, so an unpayable address made the dispute permanently
--     unresolvable against the SUBJECT's record.
--   * __'disputeDeposit'__ — the amount actually paid, recorded at open time. See 'opDisputeDeposit'
--     for why reading the oracle at resolution time instead would be a hole.
data OnchainDispute = OnchainDispute
  { disputeId :: DisputeId,
    -- | The attestation being contested. Never modified by the dispute.
    disputeTarget :: AttestationId,
    -- | The profile that opened it, proven at open time by spending that profile's user token.
    disputeOpenedBy :: ProfileId,
    -- | When it was opened, bound to the opening transaction's validity interval like every other
    -- date this protocol stores (inherited fix #4).
    disputeOpenedAt :: POSIXTime,
    disputeDeposit :: Integer,
    disputeDepositTo :: Address,
    disputeOracleToken :: AssetClass,
    -- | 'Nothing' while open. Set once, by the oracle admin, and never unset.
    disputeVerdict :: Maybe Verdict
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OnchainDispute [('OnchainDispute, 0)]

-- | Write a verdict onto a dispute, changing nothing else.
--
-- The same shape as 'applyOracleAdminAction', and for the same reason: the validator computes the
-- expected output datum on-chain with this function and compares it to the actual output, so
-- off-chain and on-chain cannot disagree about what resolving a dispute does. Anything this function
-- preserves is a field the resolution provably cannot touch.
{-# INLINEABLE resolveDispute #-}
resolveDispute :: Verdict -> OnchainDispute -> OnchainDispute
resolveDispute verdict dispute = dispute {disputeVerdict = Just verdict}

-- | Is there no open dispute against this attestation?
--
-- __An off-chain courtesy, NOT an on-chain guarantee, and the difference matters.__ "One open
-- dispute per attestation at a time" cannot be enforced on chain without an index UTxO that every
-- dispute would have to contend for, so it is not enforced on chain. What bounds dispute spam is the
-- deposit: each dispute is its own UTxO with its own deposit, so N disputes cost N deposits.
--
-- This predicate exists so the write path can refuse the duplicate a human would not have meant, and
-- so the read layer can say "contested". Nothing downstream may present it as a protocol rule —
-- there is no trace code for it, because there is no check.
--
-- Lives beside the type rather than in the off-chain library because 'applyOracleAdminAction' does
-- too: a pure function over on-chain data, used by both sides, with one definition.
{-# INLINEABLE checkNoOpenDispute #-}
checkNoOpenDispute :: AttestationId -> [OnchainDispute] -> Bool
checkNoOpenDispute target = not . any isOpenAgainstTarget
  where
    isOpenAgainstTarget d = disputeTarget d == target && disputeVerdict d == Nothing