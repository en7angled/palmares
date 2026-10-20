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
import Palmares.Onchain.Protocol (OnchainProfile, ProtocolParams)
import Palmares.Onchain.Protocol.Types (FeeConfig, OracleAdminAction, OracleParams)
import Palmares.Onchain.Validators.AttestationsValidator (AchievementsRedeemer, achievementsCompile)
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
             AchievementsRedeemer
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
          \first-class issuer. Three validators plus a configuration oracle: Minting Policy \
          \(token creation), Profiles Validator (profile lifecycle), Attestations Validator \
          \(acceptance and cleanup), Oracle Validator (pause, fees, minimum UTxO, admin key)."
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
                "NewAchievement seedTxOutRef metadata otherMetadata awardedTo awardedBy date \
                \outputIdx — mints a pending attestation CIP-68 token pair locked at the \
                \Attestations Validator. Requires the issuer's user token to be spent, validates the \
                \date against the transaction validity range, and pays the attestation fee when the \
                \oracle configures one.",
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
                "AcceptAchievement outputIdx — the subject accepts, flipping the acceptance flag and \
                \returning the token to this validator. Cleanup — permissionless dust removal for \
                \UTxOs whose datum does not parse as protocol state.",
            argumentPurpose = Set.fromList [Spend],
            argumentSchema = definitionRef @AchievementsRedeemer
          },
      validatorDatum =
        Just
          MkArgumentBlueprint
            { argumentTitle = Just "Attestation Datum",
              argumentDescription =
                Just
                  "CIP-68 datum carrying the attestation: its id, the subject it is about, the issuer \
                  \that authored it, the date, and whether the subject has accepted.",
              argumentPurpose = Set.singleton Spend,
              argumentSchema = definitionRef @()
            },
      validatorCompiled =
        Just $
          compiledValidator PlutusV3 (fromShort $ serialiseCompiledCode achievementsCompile)
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
          \protocol is paused, repriced or re-keyed without redeploying a validator.",
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
