-- | CIP-57 contract blueprint generation for the Palmares attestation protocol.
--
-- This module is the machine-readable public face of the on-chain protocol: `admin write-blueprint`
-- renders it to @docs/generated/@, and third parties build against it. Prose here is a published
-- interface, not a comment — keep it accurate.
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
import Palmares.Onchain.Validators.MintingPolicy (MintingRedeemer, mintingPolicyCompile)
import Palmares.Onchain.Validators.OracleValidator (OracleRedeemer, oracleCompile)
import Palmares.Onchain.Validators.ProfilesValidator (ProfilesRedeemer, profilesCompile)
import PlutusLedgerApi.V3 (serialiseCompiledCode)
import PlutusTx.Blueprint

-- | Complete contract blueprint for the Palmares attestation protocol.
contractBlueprint :: ProtocolParams -> ContractBlueprint
contractBlueprint mp =
  MkContractBlueprint
    { contractId = Just "Palmares",
      contractPreamble = myPreamble,
      contractValidators =
        Set.fromList
          [ mintingPolicyValidatorBlueprint mp,
            profilesValidatorBlueprint mp,
            attestationsValidatorBlueprint mp,
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

-- | Minting Policy Blueprint
mintingPolicyValidatorBlueprint :: ProtocolParams -> ValidatorBlueprint referencedTypes
mintingPolicyValidatorBlueprint mp =
  MkValidatorBlueprint
    { validatorTitle = "Palmares Minting Policy",
      validatorDescription =
        Just
          "The single minting authority for protocol tokens. Parameterised by ProtocolParams (the \
          \Profiles and Attestations validator script hashes plus the oracle token), which is how \
          \validators authenticate each other. Every minting transaction reads the oracle UTxO as a \
          \reference input and is refused while the protocol is paused. Token names are derived \
          \deterministically from a seed TxOutRef, which must be spent in the same transaction, so a \
          \name cannot be replayed. The full minted value is constrained, not just the expected token \
          \name, which is what closes the other-token-name attack.",
      validatorParameters =
        [ MkParameterBlueprint
            { parameterTitle = Just "Protocol Parameters",
              parameterDescription =
                Just
                  "Compile-time parameters: the Profiles and Attestations validator script hashes, and \
                  \the oracle token's AssetClass.",
              parameterPurpose = Set.singleton Mint,
              parameterSchema = definitionRef @ProtocolParams
            }
        ],
      validatorRedeemer =
        MkArgumentBlueprint
          { argumentTitle = Just "Minting Redeemer",
            argumentDescription =
              Just
                "NewAttestation seedTxOutRef metadata otherMetadata subject issuer kind date \
                \claimedPeriod outputIdx — mints a pending attestation CIP-68 token pair locked at \
                \the Attestations Validator. Requires the issuer's user token to be spent, validates \
                \the DATE against the transaction validity range, and pays the attestation fee when \
                \the oracle configures one. The CLAIMED PERIOD is carried through unchecked and is \
                \self-reported: no on-chain fact can establish when an affiliation or a mandate \
                \began, so the protocol does not pretend to establish it. What makes a claimed \
                \period part of the record is the subject's acceptance, not a validator rule. \
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
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode $ mintingPolicyCompile mp)
    }

-- | Profiles Validator Blueprint
profilesValidatorBlueprint :: ProtocolParams -> ValidatorBlueprint referencedTypes
profilesValidatorBlueprint _mp =
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
                \removal of a UTxO at this address whose datum is absent or does not parse; it fails \
                \if the datum is a valid protocol datum, so legitimate state cannot be swept.",
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
attestationsValidatorBlueprint :: ProtocolParams -> ValidatorBlueprint referencedTypes
attestationsValidatorBlueprint _mp =
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
                \returning the token to this validator. Cleanup — permissionless dust removal for \
                \UTxOs whose datum does not parse as protocol state.",
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
                  \RoleHeld, Endorsement), the date it was ISSUED, an optional CLAIMED PERIOD, and \
                  \whether the subject has accepted. The two dates are not the same kind of fact and \
                  \a consumer must not present them alike: the issuance date is bounded by the \
                  \transaction's validity interval and is therefore chain-attested within hours, \
                  \while the claimed period is whatever the issuer asserted and the subject \
                  \counter-signed. No validator branches on the kind — it says what a reader is being \
                  \told, not what the protocol permits.",
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
          \path's execution cost is unchanged. The oracle admin writes the verdict, read through the \
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
                "ResolveDispute verdict outputIdx — the oracle admin records VerdictUpheld or \
                \VerdictRejected, the dispute returns to this address with the verdict written and \
                \its deposit released, and the deposit is paid to the address in the datum. \
                \Cleanup — permissionless dust removal for UTxOs whose datum does not parse as \
                \protocol state; it fails if the datum IS valid dispute state.",
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
                  \the address it returns to, the oracle token used to authenticate the verdict, and \
                  \the verdict once set. The deposit amount is recorded here rather than read from \
                  \the oracle at resolution time, so that repricing the deposit cannot change what \
                  \an open dispute is owed.",
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
          \admin named by the current datum must sign each update, and the UTxO must return to the \
          \same address with at least the same value; only the datum may change. This is how the \
          \protocol is paused, repriced (fees, minimum UTxO, and the dispute deposit for NEW \
          \disputes — an open dispute's deposit is recorded in its own datum and cannot be changed \
          \from here) or re-keyed without redeploying a validator. Re-keying is \
          \OracleSetAdmin, and it is signed by the CURRENT admin: a compromised key is recoverable \
          \while it is still held, and unrecoverable once it is not.",
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
                  "Inline datum with the operational parameters: the admin public key hash, the pause \
                  \flag, the minimum UTxO value, and an optional fee configuration (fee address plus \
                  \per-action amounts).",
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
