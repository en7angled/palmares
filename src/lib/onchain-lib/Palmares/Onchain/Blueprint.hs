-- | CIP-57 contract blueprint generation for the Palmares attestation protocol.
--
-- This module is the machine-readable public face of the on-chain protocol: `admin write-blueprint`
-- renders it to @docs/generated/@, and third parties build against it. Prose here is a published
-- interface, not a comment — keep it accurate.
--
-- __The document is deployment-independent, and that is an invariant, not a happy accident.__ A
-- blueprint is what a reader hashes to decide whether the script in front of them is the script this
-- protocol published. Every byte in it must therefore be true of every deployment. Four of the five
-- validators are unparameterised, so their @compiledCode@ and @hash@ are literally every
-- deployment's. The fifth — the minting policy — is parameterised by 'ProtocolParams', which carries
-- the oracle token, which is not known until the one-shot oracle NFT is minted. For that one, CIP-57
-- has the right representation already: declare the parameter in @parameters@ and let the consumer
-- apply it. See 'mintingPolicyValidatorBlueprint' for what happens when a placeholder is baked in
-- instead. @UnitTests.Blueprint@ pins the invariant.
module Palmares.Onchain.Blueprint
  ( contractBlueprint,
    myPreamble,
  )
where

import Data.ByteString.Short (fromShort)
import Data.Set qualified as Set
import Palmares.Onchain.CIP68 (CIP68Datum)
import Palmares.Onchain.Protocol (AttestationKind, OnchainAttestation, OnchainDispute, OnchainProfile, OnchainProfileKind, ProtocolParams, Verdict)
import Palmares.Onchain.Protocol.Types (FeeConfig, OracleAdminAction, OracleParams)
import Palmares.Onchain.Validators.AttestationsValidator (AttestationsRedeemer, attestationsCompile)
import Palmares.Onchain.Validators.DisputesValidator (DisputesRedeemer, disputesCompile)
-- Deliberately not importing `mintingPolicyCompile`: compiling the policy here would require a
-- `ProtocolParams` value, and the only one available at document-generation time is a placeholder.
import Palmares.Onchain.Validators.MintingPolicy (MintingRedeemer)
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer, oracleCompile)
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer, profilesCompile)
import PlutusLedgerApi.V3 (serialiseCompiledCode)
import PlutusTx.Blueprint

-- | Complete contract blueprint for the Palmares attestation protocol.
--
-- The 'ProtocolParams' argument is accepted and ignored. It is kept so that the one caller
-- (@admin write-blueprint@) is unchanged, and because an argument that provably cannot reach the
-- output is the cheapest possible statement of the module's invariant — @UnitTests.Blueprint@ asserts
-- that two different arguments render byte-identical documents. It can be dropped whenever the
-- caller is touched for another reason.
contractBlueprint :: ProtocolParams -> ContractBlueprint
contractBlueprint _mp =
  MkContractBlueprint
    { contractId = Just "Palmares",
      contractPreamble = myPreamble,
      contractValidators =
        Set.fromList
          [ mintingPolicyValidatorBlueprint,
            profilesValidatorBlueprint,
            attestationsValidatorBlueprint,
            disputesValidatorBlueprint,
            oracleValidatorBlueprint
          ],
      contractDefinitions =
        deriveDefinitions
          @[ ProtocolParams,
             CIP68Datum OnchainProfile,
             OracleParams,
             FeeConfig,
             OracleAdminAction,
             OracleRedeemer,
             MintingRedeemer,
             ProfilesRedeemer,
             AttestationsRedeemer,
             CIP68Datum OnchainAttestation,
             OnchainAttestation,
             OnchainProfileKind,
             AttestationKind,
             DisputesRedeemer,
             CIP68Datum OnchainDispute,
             OnchainDispute,
             Verdict
           ]
    }

myPreamble :: Preamble
myPreamble =
  MkPreamble
    { preambleTitle = "Palmares",
      preambleDescription =
        Just
          "A countersigned attestation protocol for Cardano governance actors. An attestation is \
          \issued as pending by its author and becomes a permanent record only once its subject \
          \accepts it, so no claim can be attached to an identity without that identity's own \
          \on-chain consent. Authority is carried by CIP-68 user tokens rather than signature \
          \lists, which lets an organisation or a committee acting through a script be a \
          \first-class issuer. A record can also be contested: a dispute is a separate UTxO pointing \
          \at an attestation, backed by a refundable deposit, and the attestation it contests is \
          \never hidden or deleted — the dispute is shown beside it. Four validators plus a \
          \configuration oracle: Minting Policy (token creation), Profiles Validator (profile \
          \lifecycle), Attestations Validator (acceptance and cleanup), Disputes Validator (verdict \
          \and deposit return), Oracle Validator (pause, fees, minimum UTxO, dispute deposit, admin \
          \key)."
    , preambleVersion = "0.1.0",
      preamblePlutusVersion = PlutusV3,
      preambleLicense = Just "Apache-2.0"
    }

-- | Minting Policy Blueprint — the one parameterised script, and the one with no @compiledCode@.
--
-- __Why the omission.__ @mintingPolicyCompile@ applies a 'ProtocolParams' with @unsafeApplyCode@, and
-- 'ProtocolParams' carries the oracle token, which does not exist until the one-shot oracle NFT has
-- been minted at deployment. Every deployment therefore has a different minting policy and a
-- different policy hash, and no single hash can be published for it.
--
-- This blueprint used to publish one anyway: @admin write-blueprint@ passed @blueprintProtocolParams@
-- (the real sibling validator hashes plus @AssetClass (CurrencySymbol "", TokenName "")@) and the
-- policy applied to that placeholder was serialised into @compiledCode@. CIP-57 derives the @hash@
-- field from @compiledCode@, so the published document carried a 28-byte script hash that belonged to
-- no deployment and never could. That is worse than publishing nothing: a verifier comparing a
-- deployed policy against the blueprint gets a mismatch and has no way to tell a placeholder apart
-- from a substituted script — the one question they opened the blueprint to answer.
--
-- __What replaces it.__ Only the @parameters@ declaration below, which CIP-57 already has for exactly
-- this case: the consumer applies the deployment's 'ProtocolParams' to the policy and hashes the
-- result. The deployed values are published in @config/config_palmares_validators.json@.
--
-- Shipping the /unapplied/ script as @compiledCode@ would be better still, and is the CIP-57 shape
-- Aiken emits. It is not done here because @Palmares.Onchain.Validators.MintingPolicy@ exports only
-- the applied @mintingPolicyCompile@; exporting the unapplied @CompiledCode@ beside it is a one-line
-- change to that module and is the natural follow-up.
mintingPolicyValidatorBlueprint :: ValidatorBlueprint referencedTypes
mintingPolicyValidatorBlueprint =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Minting Policy",
      validatorDescription =
        Just
          "The single minting authority for protocol tokens. Parameterised by ProtocolParams (the \
          \Profiles, Attestations and Disputes validator script hashes plus the oracle token), which is how \
          \validators authenticate each other. Every minting transaction reads the oracle UTxO as a \
          \reference input and is refused while the protocol is paused. Token names are derived \
          \deterministically from a seed TxOutRef, which must be spent in the same transaction, so a \
          \name cannot be replayed. The full minted value is constrained, not just the expected token \
          \name, which is what closes the other-token-name attack. THIS ENTRY PUBLISHES NO compiledCode \
          \AND NO hash, and the omission is deliberate: the policy is applied to ProtocolParams at \
          \deployment, the oracle token inside them does not exist until the one-shot oracle NFT is \
          \minted, so every deployment has a different policy hash and no single hash is true of all \
          \of them. Apply the deployment's ProtocolParams (published in the deployed-validators \
          \config) to the policy and hash the result; a hash printed here could only be a placeholder's.",
      validatorParameters =
        [ MkParameterBlueprint
            { parameterTitle = Just "Protocol Parameters",
              parameterDescription =
                Just
                  "Compile-time parameters: the Profiles, Attestations and Disputes validator script \
                  \hashes, and the oracle token's AssetClass. The three script hashes are the same in \
                  \every deployment — those validators are unparameterised and their compiledCode is \
                  \published in this document. The oracle token is not: it is the AssetClass of the \
                  \one-shot NFT minted when the protocol is deployed, which is why this validator is \
                  \declared by parameter instead of shipped as code.",
              parameterPurpose = Set.singleton Mint,
              parameterSchema = definitionRef @ProtocolParams
            }
        ],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Minting Redeemer",
            argumentDescription =
              Just
                "MintProfile seedTxOutRef kind metadata outputIdx — mints the CIP-68 reference and \
                \user token pair for a profile, the reference token locked at the Profiles Validator \
                \and the user token sent wherever the builder chooses, since it is the authority the \
                \holder spends to act as that profile. Minting a profile claims no credential: a \
                \binding is a CredentialClaim attestation, which is a second transaction and an \
                \append-only record. \
                \NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date \
                \claimedPeriod claimedCredential outputIdx — mints a pending attestation reference token under \
                \CIP-67 PRIVATE-USE LABEL 1, deliberately not CIP-68's label 100: an attestation has no user \
                \token, so it is not a CIP-68 pair and must not claim to be one. The label is also what lets \
                \the policy TYPE an id — the subject and the issuer must both be profile ids, so an \
                \attestation about another attestation is refused rather than minted into a record nobody \
                \could ever accept. The record is locked at \
                \the Attestations Validator. Requires the issuer's user token to be spent, refuses a \
                \self-issued record unless it is a credential binding, validates \
                \the DATE against the transaction validity range, and pays the attestation fee when \
                \the oracle configures one. The CLAIMED PERIOD is carried through unchecked and is \
                \self-reported: no on-chain fact can establish when an affiliation or a mandate \
                \began, so the protocol does not pretend to establish it. What makes a claimed \
                \period part of the record is the subject's acceptance, not a validator rule. The \
                \CLAIMED CREDENTIAL is the opposite of self-reported: it is present exactly for the \
                \two credential kinds, where the credential must prove control of this transaction \
                \and the record must be self-issued, and must be absent for the other five. \
                \OpenDispute seedTxOutRef target openedBy depositTo metadata openedAt outputIdx — \
                \mints a dispute token locked at the Disputes Validator together with the oracle's \
                \current dispute deposit, which the dispute's datum then records. Requires the \
                \disputer's own user token, and does NOT touch the attestation being contested: that \
                \is what lets anyone holding a profile contest a record without the subject's or the \
                \issuer's cooperation. Opening a dispute carries no protocol fee — the refundable \
                \deposit is the only cost that bounds it.",
            argumentPurpose = Set.fromList [Mint],
            argumentSchema = definitionRef @MintingRedeemer
          },
      validatorDatum = Nothing, -- Minting policies don't have datums
      -- See the Haddock above. `Nothing` drops both `compiledCode` and `hash` from the rendered
      -- document, which is the whole point: `compiledValidator` computes the hash from the code, so
      -- any code here — placeholder included — publishes a hash to be mistaken for a deployment's.
      validatorCompiled = Nothing
    }

-- | Profiles Validator Blueprint
profilesValidatorBlueprint :: ValidatorBlueprint referencedTypes
profilesValidatorBlueprint =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Profiles Validator",
      validatorDescription =
        Just
          "Governs the profile lifecycle. Profile metadata (description and image) can be updated by \
          \whoever holds the profile's user token; the name is immutable after minting. Deletion is \
          \intentionally unsupported: a profile is the anchor of an attestation history, and that \
          \history must not become unresolvable. Unparameterised — it reads the validator addresses \
          \it needs from the datum's protocolParams.",
      validatorParameters = [],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Profiles Redeemer",
            argumentDescription =
              Just
                "UpdateProfile newMetadataFields outputIdx — updates the mutable metadata fields with \
                \size validation, requiring the profile's user token. Cleanup — permissionless \
                \removal of a UTxO at this address whose datum is absent, does not parse, or is not \
                \backed by the state NFT it names; it fails only when the UTxO's own value holds \
                \that NFT, so legitimate state cannot be swept.",
            argumentPurpose = Set.fromList [Spend],
            argumentSchema = definitionRef @ProfilesRedeemer
          },
      validatorDatum =
        Just
          MkArgumentBlueprint
            { argumentTitle = Just "Profile Datum",
              argumentDescription =
                Just
                  "CIP-68 datum carrying the profile: its id, its type, and the protocol parameters \
                  \used to resolve sibling validator addresses. The CIP-68 shape is what makes the \
                  \profile legible to wallets and marketplaces.",
              argumentPurpose = Set.singleton Spend,
              argumentSchema = definitionRef @(CIP68Datum OnchainProfile)
            },
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode profilesCompile)
    }

-- | Attestations Validator Blueprint
attestationsValidatorBlueprint :: ValidatorBlueprint referencedTypes
attestationsValidatorBlueprint =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Attestations Validator",
      validatorDescription =
        Just
          "Holds attestation tokens and enforces the second half of the two-phase protocol: an \
          \attestation minted as pending becomes permanent only when its subject spends it with the \
          \acceptance redeemer, which requires the subject's user token. That requirement is the \
          \whole anti-spam property — a claim cannot enter the record unilaterally. Also carries the \
          \permissionless cleanup path for dust.",
      validatorParameters = [],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Attestations Redeemer",
            argumentDescription =
              Just
                "AcceptAttestation outputIdx — the subject accepts, flipping the acceptance flag and \
                \returning the token to this validator. The transaction must reference the oracle \
                \UTxO named by the attestation's own oracleToken, because acceptance is refused while \
                \the protocol is paused: it is the record's one irreversible write, so it is the one \
                \the pause lever must reach. Cleanup — permissionless dust removal for \
                \UTxOs whose datum is absent, does not parse, or names a state NFT the UTxO's own \
                \value does not hold.",
            argumentPurpose = Set.fromList [Spend],
            argumentSchema = definitionRef @AttestationsRedeemer
          },
      validatorDatum =
        Just
          MkArgumentBlueprint
            { argumentTitle = Just "Attestation Datum",
              argumentDescription =
                Just
                  "CIP-68 datum carrying the attestation: its id, the subject it is about, the issuer \
                  \that authored it, its kind (one of MilestoneDelivered, AuditPassed, Affiliation, \
                  \RoleHeld, Endorsement, CredentialClaim, CredentialWithdrawal), the date it was \
                  \ISSUED, an optional CLAIMED PERIOD, an optional CREDENTIAL, the oracle token that \
                  \authenticates the pause gate on acceptance, and \
                  \whether the subject has accepted. The two dates are not the same kind of fact and \
                  \a consumer must not present them alike: the issuance date is bounded by the \
                  \transaction's validity interval and is therefore chain-attested within hours, \
                  \while the claimed period is whatever the issuer asserted and the subject \
                  \counter-signed. The kind is mostly presentational — it says what a reader is being \
                  \told — with ONE exception the protocol does enforce: the two credential kinds must \
                  \name a credential and must be self-issued, and the other five must name none, so \
                  \a binding cannot be smuggled onto a milestone where nothing would check it.",
              argumentPurpose = Set.singleton Spend,
              -- NOT `definitionRef @()`. It was, so the published blueprint described the attestation
              -- datum as Unit — the one datum a reader most needs in order to decode a record off the
              -- chain. The type was also missing from `contractDefinitions` below, which is what let
              -- the wrong reference compile without complaint.
              argumentSchema = definitionRef @(CIP68Datum OnchainAttestation)
            },
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode attestationsCompile)
    }

-- | Disputes Validator Blueprint
disputesValidatorBlueprint :: ValidatorBlueprint referencedTypes
disputesValidatorBlueprint =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Disputes Validator",
      validatorDescription =
        Just
          "Holds a dispute and the deposit behind it. A dispute is a SEPARATE UTxO pointing at an \
          \attestation — never a field on one — so it can be opened without the subject's or the \
          \issuer's cooperation, the attestation it contests is never modified, and the attestation \
          \path's execution cost is unchanged. The oracle's ARBITER credential writes the verdict — \
          \a separate field from the admin, so verdict-writing and repricing need not be the same \
          \key — read through the \
          \oracle token recorded in the dispute's own datum so a forged oracle UTxO cannot be \
          \substituted; a verdict is written once and cannot be rewritten. The deposit returns to \
          \the address the disputer named, on EITHER verdict: there is no punitive outcome, so losing \
          \a dispute costs only network fees. WHAT THIS DOES NOT ENFORCE: one open dispute per \
          \attestation at a time. That would require an index UTxO every dispute had to contend for; \
          \what bounds dispute spam is the deposit, since each dispute is its own UTxO with its own \
          \deposit. A client that needs the uniqueness property must check it itself and must not \
          \present it as a protocol guarantee.",
      validatorParameters = [],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Disputes Redeemer",
            argumentDescription =
              Just
                "ResolveDispute verdict outputIdx — the oracle's arbiter records VerdictUpheld or \
                \VerdictRejected, the dispute returns to this address with the verdict written and \
                \its deposit released, and the deposit is paid to the address in the datum. A \
                \resolution may NOT name VerdictExpired: that constructor is the clock's, not a \
                \decision. ExpireDispute outputIdx — after the dispute's own staleAfter deadline, \
                \ANYONE may close an undecided dispute as VerdictExpired, with no signature and no \
                \oracle read, and the deposit returns by the same rule as a resolution. It is the \
                \protocol's only permissionless state transition and it exists so that a deposit \
                \does not depend on the arbiter staying available. \
                \Cleanup — permissionless dust removal for UTxOs whose datum does not parse as \
                \protocol state, or names a dispute NFT the UTxO's own value does not hold; it fails \
                \only when that NFT is actually there.",
            argumentPurpose = Set.fromList [Spend],
            argumentSchema = definitionRef @DisputesRedeemer
          },
      validatorDatum =
        Just
          MkArgumentBlueprint
            { argumentTitle = Just "Dispute Datum",
              argumentDescription =
                Just
                  "CIP-68 datum carrying the dispute: its id, the attestation it contests, the \
                  \profile that opened it, when it was opened, the deposit AMOUNT ACTUALLY PAID and \
                  \the address it returns to, the oracle token used to authenticate the verdict, the \
                  \STALE-AFTER instant past which anyone may expire it, and \
                  \the verdict once set. The deposit amount is recorded here rather than read from \
                  \the oracle at resolution time, so that repricing the deposit cannot change what \
                  \an open dispute is owed; the deadline is recorded for the same reason, so that \
                  \retiming the timeout cannot move the deadline of a dispute already open.",
              argumentPurpose = Set.singleton Spend,
              argumentSchema = definitionRef @(CIP68Datum OnchainDispute)
            },
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode disputesCompile)
    }

-- | Oracle Validator Blueprint
oracleValidatorBlueprint :: ValidatorBlueprint referencedTypes
oracleValidatorBlueprint =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Oracle Validator",
      validatorDescription =
        Just
          "Unparameterised spending validator guarding the oracle UTxO that holds OracleParams. The \
          \admin credential named by the current datum must prove control of itself on each update, \
          \and the UTxO must return to the \
          \same address with at least the same value; only the datum may change. This is how the \
          \protocol is paused, repriced (fees, minimum UTxO, and the dispute deposit for NEW \
          \disputes — an open dispute's deposit is recorded in its own datum and cannot be changed \
          \from here), retimed or re-keyed without redeploying a validator. Retiming is \
          \opDisputeTimeoutMs, the sixth field and the one with teeth: it decides how long after \
          \opening a dispute must stand before ANYONE may close it as VerdictExpired, and like the \
          \deposit it applies to NEW disputes only, because each dispute's own staleAfter deadline is \
          \computed when it opens and carried in its datum. It must be strictly positive — a zero \
          \timeout would make a dispute expirable in the block after it opened. Re-keying is OracleSetAdmin for \
          \the admin and OracleSetArbiter for the arbiter, and BOTH SIDES must prove control: the \
          \outgoing one authorises, the incoming one proves it exists and is held, so a handover to \
          \a credential nobody controls cannot be made by mistake. A credential still controlled is \
          \recoverable by handing it on; one already lost is not, because the rotation needs its \
          \proof.",
      validatorParameters = [],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Oracle Redeemer",
            argumentDescription =
              Just
                "OracleUpdate outputIdx action — the output index the oracle UTxO must return to, and \
                \the admin action to apply. The validator computes the expected new datum on-chain \
                \with applyOracleAdminAction and checks the output at that index against it, so \
                \off-chain and on-chain cannot disagree about the result of an update.",
            argumentPurpose = Set.fromList [Spend],
            argumentSchema = definitionRef @OracleRedeemer
          },
      validatorDatum =
        Just
          MkArgumentBlueprint
            { argumentTitle = Just "Oracle Params Datum",
              argumentDescription =
                Just
                  "Inline datum with the operational parameters: the ADMIN CREDENTIAL, the pause \
                  \flag, the minimum UTxO value, the dispute deposit charged to NEW disputes, the \
                  \dispute timeout in milliseconds that fixes a new dispute's stale-after deadline, \
                  \an optional fee configuration (fee address plus \
                  \per-action amounts), and the ARBITER CREDENTIAL. Both are credentials rather than \
                  \key hashes, so a key and a native multisig are equally expressible and moving \
                  \from one to the other is a rotation rather than a redeployment; a key proves \
                  \control by signing, a script by spending a UTxO at its own address. The admin \
                  \sets parameters; the arbiter alone writes dispute verdicts. They are the same \
                  \credential at deployment and may be split later. Every update is checked for \
                  \well-formedness on chain: the three amounts may not be negative and the timeout \
                  \may not be zero, since a dispute whose window is empty is expirable the block \
                  \after it opens. Nothing is checked about either credential — any 28 bytes are a \
                  \possible hash, and whether anyone controls them is proved at rotation, not here.",
              argumentPurpose = Set.singleton Spend,
              argumentSchema = definitionRef @OracleParams
            },
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode oracleCompile)
    }

-- Note: OracleNFTPolicy is not included in the blueprint because it is a one-shot minting policy
-- parameterised by a TxOutRef only known at deployment time. Each deployment produces a unique
-- policy, which makes a static blueprint meaningless for it.
