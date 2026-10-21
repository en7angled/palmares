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
    opMinUTxOValue :: Integer
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
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed
  ''OracleAdminAction
  [ ('OraclePause, 0),
    ('OracleUnpause, 1),
    ('OracleSetFees, 2),
    ('OracleSetMinUTxOValue, 3),
    ('OracleSetAdmin, 4)
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

-------------------------------------------------------------------------------

-- * Type Aliases

-------------------------------------------------------------------------------

type ProfileId = AssetClass

type AttestationId = AssetClass

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
-- only place a @FeeConfig@ field is ever named is 'Palmares.Onchain.Protocol.Lookup.feeFor' — one
-- function, one naming site, no selectors. Inherited fix #1.
--
-- One constructor per minting redeemer, and the correspondence is the point: adding a redeemer without
-- adding an action leaves @feeFor@ non-exhaustive, which is a compile error rather than a silent zero.
data MintAction
  = MintActionProfile
  | MintActionAttestation
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
  deriving anyclass (HasBlueprintDefinition)

makeIsDataSchemaIndexed ''MintAction [('MintActionProfile, 0), ('MintActionAttestation, 1)]

data OnchainProfileKind
  = PersonDRep
  | Organization
  | Committee
  | Community
  | Vendor
  | Auditor
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
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
  deriving stock (Generic, Prelude.Show, Prelude.Eq)
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