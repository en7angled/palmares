{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | Core on-chain data types for the Palmares attestation protocol.
module Palmares.Onchain.Protocol.Types where

import GHC.Generics (Generic)
import PlutusLedgerApi.V1.Value (AssetClass)
import PlutusLedgerApi.V3 (Address, Credential, POSIXTime, ScriptHash)
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
  { -- | Who may change these parameters. Rotated by 'OracleSetAdmin', and that rotation needs
    -- __both__ sides to prove control (@O1@ and @O5@).
    --
    -- __A 'Credential' and not a 'PubKeyHash', decided before the first kept deployment (ADR 0005).__
    -- 'Palmares.Onchain.Utils.checkCredentialControl' reads a key credential as a signature and a
    -- script credential as a spent input at its own address, so one field expresses both a plain
    -- wallet key and a native multisig — and @PubKeyCredential@ is byte-for-byte the old behaviour,
    -- which is what makes "start on one key, move to a multisig later" a rotation rather than a
    -- redeploy. The shape this replaced is the one that foreclosed that: a 'PubKeyHash' cannot name
    -- a script, so the upgrade would have needed a new datum format, which after deployment means a
    -- new registry.
    --
    -- __Why not an authority NFT.__ A token admin makes handover a plain send, which is exactly the
    -- property you do not want at the root of trust: one phishing signature transfers it
    -- irreversibly, a lost token has no seed phrase, every admin action must spend and return it
    -- (min-ADA, an extra input and output, and a contention point between concurrent actions), and
    -- @O5@ would be gone, so a mistyped address bricks the protocol with no second side to check.
    -- It is also the failure mode @OC-03@ already records elsewhere in this protocol — authority
    -- tokens locked inside state outputs. A 'ScriptCredential' can point at a script that gates on
    -- an NFT, so this shape CONTAINS that one; the reverse is not true.
    --
    -- What rotation does and does not buy: a credential still controlled can be handed on, so
    -- compromise is recoverable while you notice in time; one already lost is not, because the
    -- rotation itself needs its proof.
    opAdmin :: Credential,
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
    opDisputeDeposit :: Integer,
    -- | How long, in MILLISECONDS, a dispute may sit undecided before anyone may close it as
    -- 'VerdictExpired'. Decided as D-A.
    --
    -- __On the oracle so that tuning it costs a command rather than a redeploy__ — the same reason
    -- 'opMinUTxOValue' and 'opDisputeDeposit' live here. And __recorded into each dispute's own
    -- datum at open time__ for the same reason the DEPOSIT is: read from here at closing time
    -- instead, an admin could raise it and push every open dispute's deadline out indefinitely,
    -- which is precisely the inaction this parameter exists to bound. The oracle sets the clock for
    -- NEW disputes; an open one's clock is history. See 'disputeStaleAfter'.
    --
    -- __Both directions are dangerous, and only one of them looks it.__ A very LARGE value is the
    -- obvious one. But ZERO is permitted and makes every new dispute closable the instant it opens,
    -- which hands the TARGET of every dispute an immediate dismissal and needs no admin action at
    -- all — the opposite of a brick and still a way to void the mechanism. A generous value is the
    -- safe default; 'Palmares.TxBuilding.Transactions' deploys 30 days.
    --
    -- One sharp edge for a SHORT timeout: @disputeStaleAfter@ is @openedAt + this@, and @openedAt@
    -- is redeemer data bounded only by @Md6@'s window — 'Palmares.Onchain.Utils.maxDateWindow',
    -- 14.4 hours — so an opener can shift their own deadline by up to that much. Immaterial against
    -- 30 days; it matters if anyone ever configures a timeout measured in hours.
    opDisputeTimeoutMs :: Integer,
    -- | Who may write a dispute verdict (@D1@). Rotated by 'OracleSetArbiter'.
    --
    -- __Separate from 'opAdmin' because the two powers have different blast radii and different
    -- frequencies.__ Setting parameters is rare and catastrophic to get wrong; writing verdicts is
    -- operational and repeated. Holding both in one credential forces one key hygiene on both: put
    -- the admin in a cold multisig and every verdict then costs a UTxO spend by that multisig,
    -- because @D1@ reads the same field through the same
    -- 'Palmares.Onchain.Utils.checkCredentialControl'.
    --
    -- __Set equal to 'opAdmin' at genesis__ ('Palmares.TxBuilding.Transactions'), so the field costs
    -- nothing to anyone who does not want the split — it is one extra credential in a datum that is
    -- read as a reference input, never per-transaction work. Appended last, and appended rather than
    -- inserted, for the reason 'OracleSetAdmin' documents: field order here is a data contract from
    -- the first kept deployment onward.
    --
    -- It is rotatable for the reason 'opAdmin' is, and the reason is not symmetry: an arbiter
    -- credential that could not be rotated would reintroduce @OC-01@ in the half of the protocol
    -- that holds other people's money. Lose it and no dispute can ever be resolved, so every open
    -- deposit is locked forever — which is precisely the outcome the 'Credential' change above
    -- exists to make recoverable.
    opArbiter :: Credential
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
    -- without this case that function preserves 'opAdmin' by construction. So the validator needs
    -- no change at all; making this function able to express the change is the whole fix, and it is
    -- that cheap because the validator was written correctly.
    --
    -- Appended at index 4, never inserted: the four indices above are a deployed-data contract from
    -- the first deployment onward.
    --
    -- __Takes a 'Credential' as of ADR 0005__, so the target of a handover may be a native multisig
    -- as well as a key. @O5@ proves control of it rather than asking for a signature, which is the
    -- same change and the reason a script target is checkable at all.
    OracleSetAdmin Credential
  | -- | Reprice the dispute deposit for NEW disputes.
    --
    -- Here for the same reason 'OracleSetMinUTxOValue' is: a protocol constant that cannot be
    -- repriced is one you must redeploy a validator to change, which is the thing the oracle exists
    -- to avoid. It cannot affect a dispute already open — that deposit is recorded in the dispute's
    -- own datum, see 'opDisputeDeposit'.
    OracleSetDisputeDeposit Integer
  | -- | Retime the stale-dispute clock for NEW disputes — D-A.
    --
    -- Here rather than baked into the validator for the reason 'OracleSetDisputeDeposit' is, and it
    -- cannot move a dispute already open: that clock is in the dispute's own datum. Appended at
    -- index 6.
    OracleSetDisputeTimeout Integer
  | -- | Hand the verdict-writing power to a new credential, leaving 'opAdmin' alone.
    --
    -- Appended at index 7. It exists because 'opArbiter' exists, and for the reason stated there:
    -- an unrotatable arbiter is @OC-01@ reintroduced over the disputes' deposits. @O5@ covers this
    -- action too — a handover is two-sided whichever power is handed over, and the arbiter is the
    -- one whose loss locks other people's money rather than merely freezing the parameters.
    OracleSetArbiter Credential
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''OracleAdminAction
  [ ('OraclePause, 0),
    ('OracleUnpause, 1),
    ('OracleSetFees, 2),
    ('OracleSetMinUTxOValue, 3),
    ('OracleSetAdmin, 4),
    ('OracleSetDisputeDeposit, 5),
    ('OracleSetDisputeTimeout, 6),
    ('OracleSetArbiter, 7)
  ]

-- | Apply an admin action to current oracle params to obtain the new params.
-- Same logic as off-chain 'TxBuilding.Operations.applyAdminAction'.
{-# INLINEABLE applyOracleAdminAction #-}
applyOracleAdminAction :: OracleAdminAction -> OracleParams -> OracleParams
applyOracleAdminAction OraclePause params = params {opPaused = True}
applyOracleAdminAction OracleUnpause params = params {opPaused = False}
applyOracleAdminAction (OracleSetFees mFeeConfig) params = params {opFeeConfig = mFeeConfig}
applyOracleAdminAction (OracleSetMinUTxOValue lovelace) params = params {opMinUTxOValue = lovelace}
applyOracleAdminAction (OracleSetAdmin newAdmin) params = params {opAdmin = newAdmin}
applyOracleAdminAction (OracleSetDisputeDeposit lovelace) params = params {opDisputeDeposit = lovelace}
applyOracleAdminAction (OracleSetDisputeTimeout ms) params = params {opDisputeTimeoutMs = ms}
applyOracleAdminAction (OracleSetArbiter newArbiter) params = params {opArbiter = newArbiter}

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
-- 5 ADA at @disputeDepositTo@, funded by whoever builds the transaction, which @D1@ says controls
-- 'opArbiter'. About 3.8 ADA out of the arbiter's pocket per dispute, repeatable by anyone who
-- opens one.
--
-- So it is a foot-gun to set and an attack once set, which is the combination worth one check. It
-- is checked on the RESULT rather than per action, so it covers all eight actions and every future
-- one by construction — the same reason @O2@ compares the output datum against this function's
-- result instead of re-deriving each field.
--
-- It deliberately says NOTHING about 'opAdmin' or 'opArbiter'. A credential cannot be ill-formed:
-- any 28 bytes are a possible key or script hash, and whether anybody controls them is not a
-- property of the datum. That question belongs to @O5@, answered by proof of control at rotation
-- time rather than by inspection here — which is the only place it CAN be answered.
--
-- Zero is permitted for the first two: a zero @opDisputeDeposit@ is a deliberate configuration
-- (disputes free to open), and a zero @opMinUTxOValue@ simply defers to the ledger's own minimum,
-- which is the real floor at every configured value anyway. The timeout is the one field where zero
-- is not a configuration — see its own note below.
{-# INLINEABLE oracleParamsAreWellFormed #-}
oracleParamsAreWellFormed :: OracleParams -> Bool
oracleParamsAreWellFormed params =
  opMinUTxOValue params >= 0
    && opDisputeDeposit params >= 0
    -- A NEGATIVE timeout would put every new dispute's `disputeStaleAfter` in the past, so it would
    -- be closable by anyone the instant it opened. Not a drain like the two above, but it voids the
    -- dispute mechanism with one keystroke and reads as a smaller number, not a wrong one.
    --
    -- __And ZERO is that same value, which the first draft of this check admitted__: @>= 0@ while
    -- the paragraph above argues against the class that contains it. With a zero timeout
    -- @disputeStaleAfter == disputeOpenedAt@, @Md6@ already forces @disputeOpenedAt@ into the
    -- opening transaction's validity range, so every later transaction's range starts after it and
    -- @D9@ holds — the dispute is expirable in the block after it opens. A dispute whose window is
    -- empty is not a configuration anyone wants; it is the degenerate case, so it is refused here.
    --
    -- What this check deliberately does NOT do is impose a FLOOR. A one-millisecond timeout is as
    -- useless as zero, but "how long must a dispute stay open" is a policy question whose answer
    -- belongs where it can be changed without a redeployment — the admin tooling and the API — not
    -- frozen into a validator. This conjunct refuses the impossible; the floor refuses the unwise.
    && opDisputeTimeoutMs params > 0

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

-- | A profile: an actor's record, and the anchor every attestation points at.
--
-- __No credential field — ADR 0003.__ It had one, @profileCredential@, set at mint by @Mp3@ and
-- cleared by a @RevokeCredential@ redeemer. An audit found that clearing irreversible and reachable
-- with the same weak proof the claim took, which made the remedy more dangerous than the hole it
-- answered: abusing @Mp3@ added a bogus profile and left the real one intact, while abusing the
-- revocation severed a credential from its entire track record for good.
--
-- A binding is now a 'CredentialClaim' attestation and its end is a 'CredentialWithdrawal' — facts
-- appended to a log that this protocol never rewrites, rather than a field with a delete button. The
-- read layer still publishes @profile_credential@; it derives it.
data OnchainProfile
  = OnchainProfile
  { profileId :: ProfileId,
    profileKind :: OnchainProfileKind,
    -- | The oracle NFT this profile's validator must read its parameters from — ADR 0006, closing
    -- @OC-08@.
    --
    -- __This was the whole 'ProtocolParams' record__, and exactly one of its four fields was ever
    -- read off a profile datum: 'ProfilesValidator' took @oracleToken (protocolParams profile)@ and
    -- nothing else. The three validator script hashes rode along in every profile datum ever
    -- minted, unread — and the minting policy already has them as its compile-time parameter, which
    -- is where a validator address belongs.
    --
    -- The cost of carrying them was measured rather than guessed. ADR 0005 added one field to
    -- 'OracleParams' and that alone cost +29 bytes in each of the two scripts that merely PARSE the
    -- oracle datum, without a line of either changing: a datum's width is paid by every script that
    -- reads it. Three unread script hashes are ~84 bytes of that tax in every profile.
    --
    -- Pinning the oracle token in the datum is still the right design and is not what changed: it
    -- is what stops a forged oracle UTxO being substituted at spend time, the same reason
    -- 'disputeOracleToken' and 'attestationOracleToken' exist.
    profileOracleToken :: AssetClass
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
  | -- | A profile binding itself to a Cardano credential — __ADR 0003__, and the reason
    -- 'OnchainProfile' no longer has a credential field.
    --
    -- Self-issued by rule (@Mc1@: issuer must equal subject), so the profile's own consent is the
    -- existing @Mf@; the credential's consent is @Mc3@, the same 'checkCredentialControl' the old
    -- @Mp3@ used. Both parties, in one record that is never rewritten.
    --
    -- __Why this is stronger than the field it replaces, not just tidier.__ @Mp3@ proved the
    -- credential consented to a TRANSACTION, which could be about anything; here the transaction's
    -- whole visible purpose is to mint this binding, so a signature on it is much harder to
    -- misrepresent. And because the record is append-only, a later 'CredentialWithdrawal' adds a
    -- fact instead of deleting one — where the D-E revocation it replaces cleared a field
    -- irreversibly, severing a credential from its whole track record.
    CredentialClaim
  | -- | A credential withdrawing from a claim — __ADR 0003__.
    --
    -- Names the same credential and the same subject as the claim it supersedes. The read layer
    -- publishes a binding only while the latest claim has no later withdrawal, so this is how a
    -- binding ends: by one more fact, never by an erasure.
    CredentialWithdrawal
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
    ('Endorsement, 4),
    -- Appended, never inserted: the five above are a deployed-data contract from the first
    -- deployment onward, the same rule 'OracleSetAdmin' and 'VerdictExpired' follow.
    ('CredentialClaim, 5),
    ('CredentialWithdrawal, 6)
  ]

-- | A claimed governance credential, __with the role those bytes play__ — ADR 0006, closing @OC-04@.
--
-- __Why the role is on chain and not inferred.__ CIP-129 puts it in a header byte:
-- @(keyType \<\< 4) | kind@, so DRep is @0x22@\/@0x23@, committee cold @0x12@\/@0x13@ and committee
-- hot @0x02@\/@0x03@. A bare 'Credential' is 28 bytes plus the key-or-script flag and nothing else,
-- so storing one threw the header away — and the renderer then had to guess. It guessed @drep@ for
-- everything, which meant a committee profile claiming @cc_cold1…@ was __published as @drep1…@ of
-- the same bytes__: an identifier that resolves to nothing in GovTool or db-sync, so a reader could
-- not verify the claim they were shown. The proof rule was always sound; the record was lossy.
--
-- __And the profile's kind is not the role.__ That was the old justification — "which governance
-- role those bytes play is the profile's @kind@" — and it does not hold: an @Organization@ may be a
-- DRep, a @Committee@ may hold both a hot and a cold credential, and nothing on chain ties
-- 'OnchainProfileKind' to either. One byte per claim buys the distinction outright.
--
-- __All three roles are claimable, including the hot one__, although it rotates. Without ADR 0003
-- that would have been an argument against it: a record pointing at a hot key rotated last month is
-- misinformation with a timestamp. With the claim/withdrawal chain it is already handled — withdraw
-- the old, claim the new — so excluding it would remove a capability and fix nothing.
--
-- Stake credentials are __not__ claimable and never were, whatever
-- 'Palmares.TxBuilding.Conversions.parseClaimCredential' used to be documented as accepting: they
-- are not CIP-129, and control of one is proved by a withdrawal in @txInfoWdrl@ rather than by a
-- spend, which is a different feature with its own cost.
data ClaimedCredential
  = ClaimedDRep Credential
  | ClaimedCCCold Credential
  | ClaimedCCHot Credential
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''ClaimedCredential
  [ ('ClaimedDRep, 0),
    ('ClaimedCCCold, 1),
    ('ClaimedCCHot, 2)
  ]

-- | The credential inside, which is what proof of control is about.
--
-- The role is for the record and for the renderer; @Mc3@ asks the same question of all three, and
-- asking it of the wrapper instead would be a second place for the roles to drift apart.
{-# INLINEABLE claimedCredentialOf #-}
claimedCredentialOf :: ClaimedCredential -> Credential
claimedCredentialOf (ClaimedDRep c) = c
claimedCredentialOf (ClaimedCCCold c) = c
claimedCredentialOf (ClaimedCCHot c) = c

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
    attestationIsAccepted :: Bool,
    -- | The credential this record binds, for the two credential kinds, and 'Nothing' for every
    -- other kind — __ADR 0003__.
    --
    -- @Mc2@ requires it present on a 'CredentialClaim' or a 'CredentialWithdrawal' and @Mc4@
    -- requires it ABSENT on the other five, so the field cannot be smuggled onto a milestone or an
    -- endorsement where nothing would check it.
    --
    -- __This is where a profile's credential lives now.__ It used to be
    -- @OnchainProfile.profileCredential@, a mutable field cleared by a destructive redeemer; an
    -- audit found that irreversible and reachable with a weak proof, so ADR 0003 moved the binding
    -- into the append-only record type this protocol already has. 'Nothing' here on an ordinary
    -- attestation is not "unclaimed" — it simply is not a claim.
    --
    -- __Carries the ROLE as of ADR 0006__ ('ClaimedCredential'), because a bare 'Credential' threw
    -- away CIP-129's header byte and the renderer then published every claim as @drep1…@. A
    -- withdrawal must therefore name the same role as the claim it supersedes, which is the right
    -- rule rather than a side effect: withdrawing a DRep claim has no business cancelling a
    -- committee-cold one over the same 28 bytes.
    attestationCredential :: Maybe ClaimedCredential,
    -- | Which oracle UTxO governs this record, so that @AcceptAttestation@ can find it.
    --
    -- __The same field as 'disputeOracleToken', for the same reason, and decided as D-C.__ An
    -- unparameterised validator cannot tell which reference input IS the oracle without the token
    -- that identifies it — and acceptance is the protocol's only irreversible write AND was the only
    -- write the pause did not reach, precisely because this datum offered no route to @opPaused@.
    -- Pausing a protocol and watching acceptances keep landing permanently is the one failure the
    -- pause exists to prevent.
    --
    -- Written by the minting policy from its own compile-time parameter (@ctxOracleToken@), never by
    -- the client: @Mk@ compares this whole datum against the output, so a forged oracle here is a
    -- mint that does not validate.
    --
    -- Only the token, not the whole 'ProtocolParams': it is all the validator needs, and a datum is
    -- paid for in min-ADA. Appended last because everything above it is what the read layer renders;
    -- this is plumbing, and the projection drops it exactly as it drops 'disputeOracleToken'.
    attestationOracleToken :: AssetClass
  }
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''OnchainAttestation [('OnchainAttestation, 0)]

-------------------------------------------------------------------------------

-- * Dispute

-------------------------------------------------------------------------------

-- | How a dispute was decided.
--
-- Two FINDINGS and no third, because the deposit comes back either way: there is no "frivolous"
-- verdict to punish, and adding one would turn the deposit into a fine the admin levies.
-- 'VerdictExpired' below is a third constructor and not a third finding — nobody decided it, which
-- is exactly what it says, and the deposit comes back there too. The
-- consequence of a verdict is entirely a read-layer one — an upheld dispute is shown beside the
-- attestation it contests, and __the attestation is never hidden or deleted__ (spec §4.3). The
-- record of a claim and the record of its being contested are both facts; suppressing the first
-- would make the second unreadable.
data Verdict
  = VerdictUpheld
  | VerdictRejected
  | -- | The clock ran out: nobody decided this, and that is what it records.
    --
    -- __Decided as D-A, and it is not a verdict on the merits.__ A dispute used to have one exit and
    -- one key — @ResolveDispute@, signed by the oracle admin — so an admin who simply did not act
    -- produced the same state as a lost key, and a pause on top of a lost key froze every open
    -- dispute forever. The one who paid for that inaction was the TARGET: a permanent accusation on
    -- a stranger's record with no on-chain move available to anyone.
    --
    -- So after @disputeStaleAfter@ __anyone__ may close it with @ExpireDispute@, which is why the
    -- name is not "withdrawn": no one retracted anything. The deposit still returns to the address
    -- the opener named, so there is nothing for a stranger to gain, and the read layer must show
    -- this as unresolved-and-closed rather than as a finding either way.
    --
    -- __Only the clock writes it, and that took a second check.__ @ResolveDispute@ takes a 'Verdict'
    -- as an unconstrained redeemer argument, so appending this constructor handed the oracle admin
    -- the power to assert an expiry with no clock — found by an independent audit of D-A and refused
    -- by @Da@. Without that guard the sentence above would be false of the chain while the read
    -- layer was told to believe it.
    --
    -- Appended at index 2, never inserted: the two indices above are a deployed-data contract from
    -- the first deployment onward — the same rule 'OracleSetAdmin' follows.
    VerdictExpired
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''Verdict [('VerdictUpheld, 0), ('VerdictRejected, 1), ('VerdictExpired, 2)]

-- PlutusTx's 'Eq', not the stock one above: under @NoImplicitPrelude@ the @==@ a validator compiles
-- is this class, and the derived @Prelude.Eq@ is invisible to it. Written out rather than derived
-- because PlutusTx has no deriving for it.
instance Eq Verdict where
  {-# INLINEABLE (==) #-}
  VerdictUpheld == VerdictUpheld = True
  VerdictRejected == VerdictRejected = True
  VerdictExpired == VerdictExpired = True
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
--
-- And a fourth, added with D-A for exactly the third one's reason:
--
--   * __'disputeStaleAfter'__ — when anyone may close this dispute as 'VerdictExpired'. Computed at
--     open time from the oracle's 'opDisputeTimeoutMs' and then fixed, because reading the oracle
--     at closing time would let an admin postpone the deadline forever — and an admin who does not
--     act is the whole failure the deadline exists to bound.
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
    -- | After this moment, @ExpireDispute@ lets ANYONE close this dispute as 'VerdictExpired'.
    --
    -- Absolute, not a duration, so the check is one comparison against the transaction's validity
    -- range and no arithmetic on a datum an attacker supplies. @disputeOpenedAt +
    -- opDisputeTimeoutMs@ at open time, written by the minting policy from the oracle it is already
    -- reading there.
    disputeStaleAfter :: POSIXTime,
    -- | 'Nothing' while open. Set once — by the oracle admin as a finding, or by anyone as
    -- 'VerdictExpired' once 'disputeStaleAfter' has passed — and never unset.
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